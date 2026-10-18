import argparse
import asyncio
import re
import secrets
from datetime import timedelta

from sqlalchemy import select

from app.config import get_settings
from app.db import Session
from app.models import OTP, User, WorkerState, utcnow
from app.security import digest
from app.services import audit, ensure_admin, lock_phone


async def issue_otp(db, phone):
    if not isinstance(phone, str) or not re.fullmatch(r"1[3-9]\d{9}", phone):
        raise ValueError("A valid mainland China mobile phone number is required")
    await lock_phone(db, phone)
    user = await db.scalar(select(User).where(User.phone == phone))
    if user and not user.active:
        raise ValueError("Account unavailable")
    for prior in (
        await db.scalars(select(OTP).where(OTP.phone == phone, OTP.used.is_(False)))
    ).all():
        prior.used = True
    code = f"{secrets.randbelow(1000000):06d}"
    db.add(
        OTP(
            phone=phone,
            code_hash=digest(phone + ":" + code + ":" + get_settings().secret),
            expires_at=utcnow() + timedelta(minutes=5),
        )
    )
    audit(
        db,
        "local_operator",
        user.id if user and user.role == "patient" else None,
        "auth.otp_issued",
        user.id if user else None,
        "cli",
    )
    return code


async def run(args):
    async with Session() as db:
        if args.command == "bootstrap":
            await ensure_admin(db)
            await db.commit()
            print("Administrator initialized; password remains in project .env")
        elif args.command == "otp":
            code = await issue_otp(db, args.phone)
            await db.commit()
            print(code)
        elif args.command == "worker-health":
            worker = await db.get(WorkerState, "main")
            if not worker or (utcnow() - worker.heartbeat).total_seconds() >= 90:
                raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["bootstrap", "otp", "worker-health"])
    parser.add_argument("--phone")
    asyncio.run(run(parser.parse_args()))
