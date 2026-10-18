import asyncio
import logging
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert

from app import services as svc
from app.config import get_settings
from app.db import Session
from app.models import Dose, Grant, Notification, User, WorkerState, utcnow

logger = logging.getLogger("wakemate.worker")


async def prepare_notifications(db, now=None):
    now = now or utcnow()
    patients = (
        await db.scalars(
            select(User).where(User.role == "patient", User.active).order_by(User.id)
        )
    ).all()
    for patient in patients:
        day = now.astimezone(ZoneInfo(patient.timezone)).date()
        await svc.materialize(db, patient.id, day)
        await svc.materialize(db, patient.id, day + timedelta(days=1))
    due = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.status.in_(["pending", "unconfirmed"]), Dose.scheduled_time <= now
            )
            .with_for_update(skip_locked=True)
        )
    ).all()
    for dose in due:
        await svc.add_notification(db, dose, dose.patient_id, "dose_reminder", now)
        if (
            dose.status == "pending"
            and (now - dose.scheduled_time).total_seconds()
            > get_settings().confirmation_window_seconds
        ):
            dose.status = "unconfirmed"
            svc.audit(
                db, "worker", dose.patient_id, "dose.unconfirmed", dose.id, "worker"
            )
            await svc.family_notifications(db, dose, "dose_unconfirmed", now)
    await db.flush()


async def deliver_notifications(db, now=None):
    fixed_now = now
    now = now or utcnow()
    deliveries = (
        await db.scalars(
            select(Notification)
            .where(
                Notification.status.in_(["queued", "retrying"]),
                Notification.next_attempt_at <= now,
            )
            .order_by(Notification.created_at)
            .limit(100)
            .with_for_update(skip_locked=True)
        )
    ).all()
    async with httpx.AsyncClient(
        timeout=10, follow_redirects=False, trust_env=False
    ) as client:
        for item in deliveries:
            if fixed_now is None:
                now = utcnow()
            recipient = await db.get(User, item.target_id)
            dose = await db.get(Dose, item.dose_id)
            if not recipient or not recipient.active or dose.status == "cancelled":
                item.status = "cancelled"
                continue
            if item.event == "dose_reminder" and dose.status == "confirmed":
                item.status = "cancelled"
                continue
            if item.target_id != item.patient_id:
                # A separate budget lock prevents concurrent workers exceeding a family's daily limit.
                budget_key = (
                    f"wakemate-notification-budget:{item.patient_id}:{item.target_id}"
                )
                budget_locked = await db.scalar(
                    select(
                        func.pg_try_advisory_xact_lock(
                            func.hashtextextended(budget_key, 0)
                        )
                    )
                )
                if not budget_locked:
                    continue
                grants = (
                    await db.scalars(
                        select(Grant).where(
                            Grant.patient_id == item.patient_id,
                            Grant.caregiver_id == item.target_id,
                            Grant.status == "active",
                        )
                    )
                ).all()
                if not any(
                    "reminders:read" in g.scopes
                    and (not g.expires_at or g.expires_at > now)
                    for g in grants
                ):
                    item.status = "cancelled"
                    continue
                patient = await db.get(User, item.patient_id)
                options = {**svc.DEFAULT_SETTINGS, **patient.settings}
                if not options["family_push_enabled"]:
                    item.status = "cancelled"
                    continue
                local_now = now.astimezone(ZoneInfo(patient.timezone))
                start, end = (
                    time.fromisoformat(options["quiet_start"]),
                    time.fromisoformat(options["quiet_end"]),
                )
                clock = local_now.time().replace(tzinfo=None)
                quiet = (
                    start <= clock < end
                    if start < end
                    else clock >= start or clock < end
                    if start != end
                    else False
                )
                if quiet:
                    item.next_attempt_at = now + timedelta(minutes=5)
                    continue
                day_start = datetime.combine(
                    local_now.date(), time.min, local_now.tzinfo
                ).astimezone(timezone.utc)
                day_end = datetime.combine(
                    local_now.date() + timedelta(days=1), time.min, local_now.tzinfo
                ).astimezone(timezone.utc)
                count = await db.scalar(
                    select(func.count())
                    .select_from(Notification)
                    .where(
                        Notification.target_id == item.target_id,
                        Notification.patient_id == item.patient_id,
                        Notification.delivered_at >= day_start,
                        Notification.delivered_at < day_end,
                        Notification.status.in_(["inbox_ready", "delivered"]),
                    )
                )
                if count >= options["daily_push_limit"]:
                    item.next_attempt_at = day_end
                    continue
            item.attempts += 1
            if item.channel == "inbox":
                item.status = "inbox_ready"
                item.delivered_at, item.last_error = now, None
                svc.audit(
                    db,
                    "worker",
                    item.patient_id,
                    "notification.inbox_ready",
                    item.id,
                    "worker",
                )
                continue
            try:
                response = await client.post(
                    get_settings().notification_webhook,
                    headers={
                        "Authorization": "Bearer "
                        + get_settings().notification_webhook_token,
                        "Idempotency-Key": item.id,
                    },
                    json={
                        "notification_id": item.id,
                        "target_id": item.target_id,
                        **item.payload,
                    },
                )
                response.raise_for_status()
                item.status, item.last_error = "delivered", None
                item.delivered_at = fixed_now if fixed_now is not None else utcnow()
            except httpx.HTTPError as exc:
                item.last_error = type(exc).__name__
                item.status = "failed" if item.attempts >= 5 else "retrying"
                item.next_attempt_at = now + timedelta(
                    seconds=min(3600, 30 * 2**item.attempts)
                )
            svc.audit(
                db,
                "worker",
                item.patient_id,
                "notification." + item.status,
                item.id,
                "worker",
            )


async def worker_heartbeat(db, now):
    await db.execute(
        insert(WorkerState)
        .values(id="main", heartbeat=now)
        .on_conflict_do_update(index_elements=[WorkerState.id], set_={"heartbeat": now})
    )


async def run_once(db, now=None):
    now = now or utcnow()
    await prepare_notifications(db, now)
    await deliver_notifications(db, now)
    await worker_heartbeat(db, now)


async def main():
    logging.basicConfig(level=logging.INFO)
    logging.getLogger("httpx").setLevel(logging.CRITICAL)
    while True:
        try:
            async with Session() as db:
                await prepare_notifications(db)
                await worker_heartbeat(db, utcnow())
                await db.commit()
            # Release patient/dose locks before contacting an external delivery provider.
            async with Session() as db:
                await deliver_notifications(db)
                await worker_heartbeat(db, utcnow())
                await db.commit()
        except Exception as exc:
            logger.error("worker_iteration_failed type=%s", type(exc).__name__)
        await asyncio.sleep(get_settings().worker_interval_seconds)


if __name__ == "__main__":
    asyncio.run(main())
