import json
import secrets
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Literal

import jwt
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import Field, SecretStr
from sqlalchemy import func, or_, select, text
from sqlalchemy.exc import IntegrityError

from app import services as svc
from app.config import get_settings
from app.db import TransactionRoute, get_db
from app.mcp_connections import (
    configure_connection,
    connection_json,
    lock_configurations,
    validate_endpoint,
)
from app.models import (
    Audit,
    Binding,
    Device,
    DeviceEvent,
    Dose,
    Evidence,
    Grant,
    LoginAttempt,
    MCPConnection,
    Notification,
    OTP,
    Plan,
    User,
    WorkerState,
    utcnow,
)
from app.schemas import (
    ConfirmInput,
    CorrectionInput,
    DeviceEventInput,
    DeviceInput,
    Input,
    PlanInput,
    ProfileInput,
    RegisterInput,
    SettingsInput,
    UserCreate,
)
from app.security import digest, hash_password, verify_password

settings = get_settings()
app = FastAPI(title="WakeMate API", version="1.0.0")
app.router.route_class = TransactionRoute
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins.split(","),
    allow_methods=["GET", "POST", "PUT", "DELETE"],
    allow_headers=["Authorization", "Content-Type", "Idempotency-Key"],
    allow_credentials=False,
)


@app.middleware("http")
async def request_identity(request, call_next):
    request.state.request_id = secrets.token_hex(16)
    response = await call_next(request)
    response.headers["X-Request-ID"] = request.state.request_id
    response.headers["Cache-Control"] = (
        "no-store" if request.url.path.startswith("/api/") else "no-cache"
    )
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.exception_handler(HTTPException)
async def http_error(request, exc):
    return JSONResponse(
        {"detail": exc.detail, "request_id": request.state.request_id},
        status_code=exc.status_code,
    )


@app.exception_handler(RequestValidationError)
async def validation_error(request, exc):
    # Do not echo validation inputs: they can contain passwords or tokens.
    return JSONResponse(
        {
            "detail": [
                {"loc": e["loc"], "type": e["type"], "msg": e["msg"]}
                for e in exc.errors()
            ],
            "request_id": request.state.request_id,
        },
        status_code=422,
    )


@app.exception_handler(IntegrityError)
async def conflict(request, exc):
    return JSONResponse(
        {
            "detail": "Conflicting object or duplicate request",
            "request_id": request.state.request_id,
        },
        status_code=409,
    )


@app.exception_handler(Exception)
async def unexpected(request, exc):
    import logging

    logging.getLogger("wakemate").error(
        "request_failed id=%s type=%s", request.state.request_id, type(exc).__name__
    )
    return JSONResponse(
        {"detail": "Internal service error", "request_id": request.state.request_id},
        status_code=500,
    )


def bearer(authorization):
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Authentication required")
    return authorization[7:]


async def current_user(
    authorization: str | None = Header(default=None), db=Depends(get_db)
):
    try:
        claims = jwt.decode(
            bearer(authorization),
            settings.secret,
            algorithms=["HS256"],
            options={"require": ["exp", "sub", "iat"]},
            audience="wakemate-app",
        )
    except jwt.PyJWTError as exc:
        raise HTTPException(401, "Invalid or expired session") from exc
    user = await db.get(User, claims["sub"])
    if not user or not user.active:
        raise HTTPException(401, "Account unavailable")
    return user


async def admin(user=Depends(current_user)):
    if user.role != "admin":
        raise HTTPException(403, "Administrator access required")
    return user


def token_response(user):
    now = utcnow()
    token = jwt.encode(
        {
            "sub": user.id,
            "iat": now,
            "exp": now + timedelta(seconds=settings.token_seconds),
            "aud": "wakemate-app",
        },
        settings.secret,
        algorithm="HS256",
    )
    return {
        "access_token": token,
        "token_type": "bearer",
        "user_id": user.id,
        "role": user.role,
        "expires_in": settings.token_seconds,
    }


class PasswordLogin(Input):
    username: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=1, max_length=128)


class PhoneInput(Input):
    phone: str = Field(pattern=r"^1[3-9]\d{9}$")


class OTPLogin(PhoneInput):
    otp: str = Field(pattern=r"^\d{6}$")


async def login_limit(db, key, limit=10, window_seconds=900):
    now = utcnow()
    key = digest(key)
    # Row locks alone cannot serialize concurrent creation of a new limit key.
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended("wakemate:login:" + key, 0)
            )
        )
    )
    row = await db.get(LoginAttempt, key, with_for_update=True)
    if row is None:
        row = LoginAttempt(
            key=key, count=0, reset_at=now + timedelta(seconds=window_seconds)
        )
        db.add(row)
    if row.reset_at < now:
        row.count, row.reset_at = 0, now + timedelta(seconds=window_seconds)
    if row.count >= limit:
        raise HTTPException(429, "Too many login attempts; try later")
    row.count += 1
    await db.commit()


@app.post("/api/auth/password")
async def password_login(body: PasswordLogin, request: Request, db=Depends(get_db)):
    source = request.client.host if request.client else "unknown"
    await login_limit(db, "ip:" + source, limit=30, window_seconds=60)
    await login_limit(db, body.username)
    user = await db.scalar(
        select(User).where(User.username == body.username, User.active)
    )
    if not user or not verify_password(body.password, user.password_hash):
        raise HTTPException(401, "Invalid username or password")
    svc.audit(
        db,
        user.id,
        user.id if user.role == "patient" else None,
        "auth.login",
        user.id,
        request.state.request_id,
    )
    return token_response(user)


@app.post("/api/auth/register", status_code=201)
async def password_register(
    body: RegisterInput, request: Request, db=Depends(get_db)
):
    source = request.client.host if request.client else "unknown"
    await login_limit(db, "ip:" + source, limit=30, window_seconds=60)
    await login_limit(db, body.username, limit=10, window_seconds=900)
    await svc.lock_username(db, body.username)
    if await db.scalar(select(User).where(User.username == body.username)):
        raise HTTPException(409, "Username already exists")
    user = User(
        username=body.username,
        phone=None,
        display_name=body.display_name or body.username,
        role="patient",
        timezone=body.timezone,
        password_hash=hash_password(body.password),
        settings=svc.DEFAULT_SETTINGS,
    )
    db.add(user)
    await db.flush()
    svc.audit(
        db,
        user.id,
        user.id,
        "account.created",
        user.id,
        request.state.request_id,
        {"source": "app_password"},
    )
    return token_response(user)


@app.post("/api/auth/otp")
async def request_otp(body: PhoneInput):
    raise HTTPException(
        503,
        "SMS delivery is not configured. Local operator can issue an OTP with the CLI.",
    )


@app.post("/api/auth/login")
async def otp_login(body: OTPLogin, request: Request, db=Depends(get_db)):
    source = request.client.host if request.client else "unknown"
    await login_limit(db, "ip:" + source, limit=30, window_seconds=60)
    await login_limit(db, "otp:" + body.phone)
    await svc.lock_phone(db, body.phone)
    challenge = await db.scalar(
        select(OTP)
        .where(OTP.phone == body.phone, OTP.used.is_(False))
        .order_by(OTP.created_at.desc())
        .limit(1)
        .with_for_update()
    )
    if not challenge or challenge.expires_at < utcnow() or challenge.attempts >= 5:
        raise HTTPException(401, "OTP invalid or expired")
    challenge.attempts += 1
    if challenge.code_hash != digest(
        body.phone + ":" + body.otp + ":" + settings.secret
    ):
        await db.commit()
        raise HTTPException(401, "OTP invalid or expired")
    user = await db.scalar(
        select(User).where(User.phone == body.phone).with_for_update()
    )
    if user and not user.active:
        raise HTTPException(401, "Account unavailable")
    if user is None:
        user = User(
            username=body.phone,
            phone=body.phone,
            display_name=f"用户{body.phone[-4:]}",
            role="patient",
            timezone="Asia/Shanghai",
            password_hash=hash_password(secrets.token_urlsafe(48)),
            settings=svc.DEFAULT_SETTINGS,
        )
        db.add(user)
        await db.flush()
        svc.audit(
            db,
            user.id,
            user.id,
            "account.created",
            user.id,
            request.state.request_id,
            {"source": "app_otp"},
        )
    challenge.used = True
    svc.audit(
        db,
        user.id,
        user.id if user.role == "patient" else None,
        "auth.otp_login",
        user.id,
        request.state.request_id,
    )
    return token_response(user)


@app.get("/api/auth/me")
async def me(user=Depends(current_user)):
    return svc.user_json(user)


@app.post("/api/auth/fcm-token")
async def fcm_token(user=Depends(current_user)):
    raise HTTPException(
        503, "FCM provider is not configured; no push subscription was registered"
    )


@app.get("/api/plans")
async def plans(user=Depends(current_user), db=Depends(get_db)):
    svc.require_patient(user)
    return await svc.list_plans(db, user.id)


@app.post("/api/plans", status_code=201)
async def create_plan(
    body: PlanInput, request: Request, user=Depends(current_user), db=Depends(get_db)
):
    svc.require_patient(user)
    await svc.lock_patient(db, user.id)
    values = body.model_dump()
    values["timezone"] = body.timezone or user.timezone
    plan = Plan(patient_id=user.id, **values)
    db.add(plan)
    await db.flush()
    await svc.materialize(db, user.id)
    svc.audit(db, user.id, user.id, "plan.created", plan.id, request.state.request_id)
    return await svc.plan_json(db, plan)


@app.put("/api/plans/{plan_id}")
async def update_plan(
    plan_id: str,
    body: PlanInput,
    request: Request,
    user=Depends(current_user),
    db=Depends(get_db),
):
    svc.require_patient(user)
    await svc.lock_patient(db, user.id)
    plan = await db.scalar(
        select(Plan)
        .where(
            Plan.id == plan_id, Plan.patient_id == user.id, Plan.deleted_at.is_(None)
        )
        .with_for_update()
    )
    if not plan:
        raise HTTPException(404, "Plan not found")
    future = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.plan_id == plan.id,
                Dose.status.in_(["pending", "unconfirmed"]),
                Dose.scheduled_time > utcnow(),
            )
            .with_for_update()
        )
    ).all()
    for dose in future:
        dose.status = "cancelled"
    for key, value in body.model_dump().items():
        setattr(plan, key, value if key != "timezone" else value or plan.timezone)
    plan.version += 1
    plan.version_effective_at = utcnow()
    await db.flush()
    await svc.materialize(db, user.id)
    svc.audit(
        db,
        user.id,
        user.id,
        "plan.updated",
        plan.id,
        request.state.request_id,
        {"version": plan.version},
    )
    return await svc.plan_json(db, plan)


@app.delete("/api/plans/{plan_id}")
async def delete_plan(
    plan_id: str, request: Request, user=Depends(current_user), db=Depends(get_db)
):
    svc.require_patient(user)
    await svc.lock_patient(db, user.id)
    plan = await db.scalar(
        select(Plan)
        .where(
            Plan.id == plan_id, Plan.patient_id == user.id, Plan.deleted_at.is_(None)
        )
        .with_for_update()
    )
    if not plan:
        raise HTTPException(404, "Plan not found")
    plan.active, plan.deleted_at = False, utcnow()
    for dose in (
        await db.scalars(
            select(Dose).where(
                Dose.plan_id == plan_id,
                Dose.status.in_(["pending", "unconfirmed"]),
                Dose.scheduled_time > utcnow(),
            )
        )
    ).all():
        dose.status = "cancelled"
    svc.audit(db, user.id, user.id, "plan.deleted", plan_id, request.state.request_id)
    return {"message": "Plan deactivated; historical doses retained"}


@app.get("/api/doses")
async def doses(
    date: date | None = None, user=Depends(current_user), db=Depends(get_db)
):
    svc.require_patient(user)
    return await svc.list_doses(db, user.id, date)


@app.post("/api/records/confirm")
async def confirm(
    body: ConfirmInput,
    request: Request,
    idempotency_key: str | None = Header(default=None),
    user=Depends(current_user),
    db=Depends(get_db),
):
    return await svc.confirm(db, user, body, idempotency_key, request.state.request_id)


@app.post("/api/records/{dose_id}/corrections")
async def correct(
    dose_id: str,
    body: CorrectionInput,
    request: Request,
    idempotency_key: str | None = Header(default=None),
    user=Depends(current_user),
    db=Depends(get_db),
):
    return await svc.correct(
        db, user, dose_id, body, idempotency_key, request.state.request_id
    )


@app.get("/api/records")
async def records(
    days: int = Query(default=7, ge=1, le=90),
    user=Depends(current_user),
    db=Depends(get_db),
):
    svc.require_patient(user)
    return await svc.list_records(db, user.id, days)


@app.get("/api/records/stats")
async def record_stats(
    days: int = Query(default=30, ge=1, le=365),
    user=Depends(current_user),
    db=Depends(get_db),
):
    svc.require_patient(user)
    return await svc.stats(db, user.id, days)


@app.get("/api/settings")
async def user_settings(user=Depends(current_user)):
    return {**svc.DEFAULT_SETTINGS, **user.settings}


@app.put("/api/settings")
async def update_settings(
    body: SettingsInput,
    request: Request,
    user=Depends(current_user),
    db=Depends(get_db),
):
    user.settings = {
        **svc.DEFAULT_SETTINGS,
        **user.settings,
        **body.model_dump(exclude_none=True),
    }
    svc.audit(
        db, user.id, user.id, "settings.updated", user.id, request.state.request_id
    )
    return user.settings


@app.put("/api/settings/profile")
async def profile(
    body: ProfileInput, request: Request, user=Depends(current_user), db=Depends(get_db)
):
    for key, value in body.model_dump(exclude_none=True).items():
        setattr(user, key, value)
    svc.audit(
        db, user.id, user.id, "profile.updated", user.id, request.state.request_id
    )
    return svc.user_json(user)


class GrantInput(Input):
    caregiver_id: str
    expires_at: datetime | None = None


@app.get("/api/grants")
async def grants(user=Depends(current_user), db=Depends(get_db)):
    rows = (
        await db.scalars(
            select(Grant).where(
                or_(Grant.patient_id == user.id, Grant.caregiver_id == user.id)
            )
        )
    ).all()
    return [svc.grant_json(g) for g in rows]


@app.post("/api/grants", status_code=201)
async def invite(
    body: GrantInput, request: Request, user=Depends(current_user), db=Depends(get_db)
):
    svc.require_patient(user)
    caregiver = await db.get(User, body.caregiver_id)
    if not caregiver or caregiver.role != "caregiver" or not caregiver.active:
        raise HTTPException(404, "Caregiver account not found")
    if body.expires_at and (
        body.expires_at.tzinfo is None or body.expires_at <= utcnow()
    ):
        raise HTTPException(
            422, "Grant expiry must be a future timezone-aware datetime"
        )
    grant = Grant(
        patient_id=user.id, caregiver_id=caregiver.id, expires_at=body.expires_at
    )
    db.add(grant)
    await db.flush()
    svc.audit(db, user.id, user.id, "grant.invited", grant.id, request.state.request_id)
    return svc.grant_json(grant)


@app.post("/api/grants/{grant_id}/{action}")
async def grant_action(
    grant_id: str,
    action: Literal["accept", "activate", "revoke"],
    request: Request,
    user=Depends(current_user),
    db=Depends(get_db),
):
    grant = await db.get(Grant, grant_id, with_for_update=True)
    if not grant:
        raise HTTPException(404, "Grant not found")
    if action == "accept":
        if (
            user.role != "caregiver"
            or user.id != grant.caregiver_id
            or grant.status != "invited"
        ):
            raise HTTPException(403, "Invitation cannot be accepted")
        grant.status = "awaiting_patient"
    else:
        if user.role != "patient" or user.id != grant.patient_id:
            raise HTTPException(403, "Patient authorization required")
        if action == "activate" and grant.status != "awaiting_patient":
            raise HTTPException(409, "Caregiver must accept before patient approval")
        grant.status = "active" if action == "activate" else "revoked"
    svc.audit(
        db,
        user.id,
        grant.patient_id,
        "grant." + action,
        grant.id,
        request.state.request_id,
    )
    return svc.grant_json(grant)


@app.get("/api/patients/{patient_id}/{resource}")
async def family_read(
    patient_id: str,
    resource: Literal["plans", "doses", "records", "stats"],
    user=Depends(current_user),
    db=Depends(get_db),
):
    await svc.patient_access(
        db, user, patient_id, "plans:read" if resource == "plans" else "records:read"
    )
    methods = {
        "plans": svc.list_plans,
        "doses": svc.list_doses,
        "records": svc.list_records,
        "stats": svc.stats,
    }
    return await methods[resource](db, patient_id)


@app.get("/api/device")
async def devices(user=Depends(current_user), db=Depends(get_db)):
    return await svc.list_devices(db, user.id)


class ClaimInput(Input):
    device_sn: str
    claim_code: str = Field(min_length=8, max_length=128)


@app.post("/api/device/bind")
async def claim(
    body: ClaimInput, request: Request, user=Depends(current_user), db=Depends(get_db)
):
    svc.require_patient(user)
    device = await db.scalar(
        select(Device)
        .where(Device.device_sn == body.device_sn, Device.active)
        .with_for_update()
    )
    if (
        not device
        or device.patient_id
        or device.claim_hash != digest(body.claim_code)
        or device.claim_expires_at <= utcnow()
    ):
        raise HTTPException(403, "Device claim invalid or expired")
    device.patient_id, device.claim_hash = user.id, None
    svc.audit(
        db, user.id, user.id, "device.claimed", device.id, request.state.request_id
    )
    return svc.device_json(device)


async def current_device(
    authorization: str | None = Header(default=None), db=Depends(get_db)
):
    device = await db.scalar(
        select(Device)
        .where(Device.token_hash == digest(bearer(authorization)), Device.active)
        .with_for_update()
    )
    if not device or not device.patient_id:
        raise HTTPException(401, "Bound device credential required")
    return device


@app.post("/api/device/events")
async def device_event(
    body: DeviceEventInput,
    request: Request,
    device=Depends(current_device),
    db=Depends(get_db),
):
    now = utcnow()
    if (
        body.occurred_at.tzinfo is None
        or body.occurred_at > now + timedelta(minutes=5)
        or body.occurred_at < now - timedelta(days=30)
    ):
        raise HTTPException(
            422, "Device timestamp must be timezone-aware and within 30 days"
        )
    payload_hash = digest(json.dumps(body.model_dump(mode="json"), sort_keys=True))
    previous = await db.scalar(
        select(DeviceEvent).where(
            DeviceEvent.device_id == device.id, DeviceEvent.event_id == body.event_id
        )
    )
    if previous:
        if previous.payload_hash != payload_hash:
            raise HTTPException(409, "Event id reused with a different payload")
        return {"id": previous.id, "duplicate": True}
    dose = None
    if body.dose_instance_id:
        dose = await db.scalar(
            select(Dose).where(
                Dose.id == body.dose_instance_id, Dose.patient_id == device.patient_id
            )
        )
        if not dose:
            raise HTTPException(404, "Dose not associated with this device owner")
    event = DeviceEvent(
        device_id=device.id,
        event_id=body.event_id,
        kind=body.kind,
        occurred_at=body.occurred_at,
        payload_hash=payload_hash,
    )
    db.add(event)
    if body.kind != "heartbeat":
        db.add(
            Evidence(
                patient_id=device.patient_id,
                dose_id=dose.id if dose else None,
                actor_id=device.id,
                kind=body.kind,
                occurred_at=body.occurred_at,
                request_id=request.state.request_id,
                detail={"device_id": device.id, "event_id": body.event_id},
            )
        )
    device.last_sync_at = now
    device.state = {
        **device.state,
        **body.model_dump(exclude_none=True, include={"battery", "bead_remain"}),
        "last_heartbeat": now.isoformat(),
    }
    await db.flush()
    svc.audit(
        db,
        device.id,
        device.patient_id,
        "device." + body.kind,
        event.id,
        request.state.request_id,
    )
    return {"id": event.id, "duplicate": False, "dose_confirmed": False}


@app.get("/api/device/plans")
async def device_plans(device=Depends(current_device), db=Depends(get_db)):
    return await svc.list_plans(db, device.patient_id)


class AckInput(Input):
    plan_id: str
    version: int = Field(ge=1)


@app.post("/api/device/ack")
async def device_ack(
    body: AckInput, request: Request, device=Depends(current_device), db=Depends(get_db)
):
    plan = await db.get(Plan, body.plan_id)
    if not plan or plan.patient_id != device.patient_id or plan.version != body.version:
        raise HTTPException(409, "Plan version does not match")
    device.ack_versions = {**device.ack_versions, plan.id: body.version}
    svc.audit(
        db,
        device.id,
        device.patient_id,
        "device.plan_ack",
        plan.id,
        request.state.request_id,
    )
    return {"message": "Plan version acknowledged"}


@app.get("/api/notifications")
async def inbox(user=Depends(current_user), db=Depends(get_db)):
    notifications = (
        await db.scalars(
            select(Notification)
            .where(
                Notification.target_id == user.id,
                Notification.status.in_(["inbox_ready", "delivered"]),
            )
            .order_by(Notification.created_at.desc())
            .limit(200)
        )
    ).all()
    visible = []
    for item in notifications:
        if item.patient_id != user.id:
            try:
                await svc.patient_access(db, user, item.patient_id, "reminders:read")
            except HTTPException:
                continue
        visible.append(notification_json(item))
    return visible


@app.post("/api/notifications/{notification_id}/read")
async def read_notification(
    notification_id: str, user=Depends(current_user), db=Depends(get_db)
):
    item = await db.scalar(
        select(Notification)
        .where(Notification.id == notification_id, Notification.target_id == user.id)
        .with_for_update()
    )
    if not item or item.status not in {"inbox_ready", "delivered"}:
        raise HTTPException(404, "Notification not found")
    if item.patient_id != user.id:
        await svc.patient_access(db, user, item.patient_id, "reminders:read")
    item.read_at = item.read_at or utcnow()
    return notification_json(item)


def notification_json(item):
    return {
        "id": item.id,
        "patient_id": item.patient_id,
        "dose_instance_id": item.dose_id,
        "target_id": item.target_id,
        "event": item.event,
        "status": item.status,
        "channel": item.channel,
        "attempts": item.attempts,
        "last_error": item.last_error,
        "created_at": item.created_at,
        "read_at": item.read_at,
        "delivered_at": item.delivered_at,
        "next_attempt_at": item.next_attempt_at,
        "payload": item.payload,
    }


@app.post("/api/mcp/tools/{name}")
async def mcp_tool(
    name: str,
    request: Request,
    args: dict = Body(default={}),
    authorization: str | None = Header(default=None),
    db=Depends(get_db),
):
    if name not in {
        "get_today_doses",
        "get_dose_status",
        "get_recent_medication_history",
        "get_medication_plans",
        "get_device_status",
    }:
        raise HTTPException(404, "Read-only MCP tool not found")
    try:
        return await svc.mcp_call(
            db, bearer(authorization), name, args, request.state.request_id
        )
    except HTTPException as exc:
        await db.rollback()
        svc.audit(
            db,
            "mcp",
            None,
            "mcp.rejected",
            None,
            request.state.request_id,
            {"tool": name, "status": exc.status_code},
        )
        await db.commit()
        raise


@app.post("/api/admin/users", status_code=201)
async def create_user(
    body: UserCreate, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    await svc.lock_phone(db, body.phone)
    user = User(
        username=body.phone,
        phone=body.phone,
        display_name=body.display_name,
        role=body.role,
        timezone=body.timezone,
        password_hash=hash_password(body.password),
        settings=svc.DEFAULT_SETTINGS,
    )
    db.add(user)
    await db.flush()
    svc.audit(
        db,
        actor.id,
        user.id if user.role == "patient" else None,
        "account.created",
        user.id,
        request.state.request_id,
    )
    return svc.user_json(user)


@app.put("/api/admin/users/{user_id}")
async def update_patient_account(
    user_id: str,
    body: ProfileInput,
    request: Request,
    actor=Depends(admin),
    db=Depends(get_db),
):
    values = body.model_dump(exclude_none=True)
    if not values:
        raise HTTPException(422, "At least one profile field is required")
    await svc.lock_patient(db, user_id)
    user = await db.scalar(
        select(User).where(User.id == user_id, User.role == "patient").with_for_update()
    )
    if user is None:
        raise HTTPException(404, "Patient not found")
    for key, value in values.items():
        setattr(user, key, value)
    svc.audit(
        db,
        actor.id,
        user.id,
        "account.updated",
        user.id,
        request.state.request_id,
        {"fields": sorted(values)},
    )
    return svc.user_json(user)


@app.get("/api/admin/patients")
async def patients(actor=Depends(admin), db=Depends(get_db)):
    return [
        svc.user_json(u)
        for u in (
            await db.scalars(
                select(User).where(User.role != "admin").order_by(User.created_at)
            )
        ).all()
    ]


@app.get("/api/admin/patients/{patient_id}/{resource}")
async def admin_patient(
    patient_id: str,
    resource: Literal["plans", "doses", "records", "grants", "devices"],
    actor=Depends(admin),
    db=Depends(get_db),
):
    patient = await db.get(User, patient_id)
    if not patient or patient.role != "patient":
        raise HTTPException(404, "Patient not found")
    if resource == "grants":
        return [
            svc.grant_json(g)
            for g in (
                await db.scalars(select(Grant).where(Grant.patient_id == patient_id))
            ).all()
        ]
    methods = {
        "plans": svc.list_plans,
        "doses": svc.list_doses,
        "records": svc.list_evidence_doses,
        "devices": svc.list_devices,
    }
    return await methods[resource](db, patient_id)


@app.post("/api/admin/devices", status_code=201)
async def provision(
    body: DeviceInput, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    claim_code, token = secrets.token_urlsafe(16), secrets.token_urlsafe(32)
    device = Device(
        **body.model_dump(),
        token_hash=digest(token),
        claim_hash=digest(claim_code),
        claim_expires_at=utcnow() + timedelta(hours=24),
    )
    db.add(device)
    await db.flush()
    svc.audit(
        db, actor.id, None, "device.provisioned", device.id, request.state.request_id
    )
    return {**svc.device_json(device), "claim_code": claim_code, "device_token": token}


@app.get("/api/admin/devices")
async def admin_devices(actor=Depends(admin), db=Depends(get_db)):
    return [
        svc.device_json(d)
        for d in (await db.scalars(select(Device).order_by(Device.created_at))).all()
    ]


class BindingInput(Input):
    patient_id: str
    label: str = Field(min_length=1, max_length=100)
    endpoint: SecretStr | None = None


class ConnectionInput(Input):
    endpoint: SecretStr


def binding_json(binding, connection=None):
    return {
        "id": binding.id,
        "patient_id": binding.patient_id,
        "label": binding.label,
        "active": binding.active,
        "last_called_at": binding.last_called_at,
        "created_at": binding.created_at,
        "connection": connection_json(connection),
    }


@app.post("/api/admin/mcp-bindings", status_code=201)
async def create_binding(
    body: BindingInput, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    endpoint = (
        validate_endpoint(body.endpoint.get_secret_value()) if body.endpoint else None
    )
    if endpoint:
        await lock_configurations(db)
    patient = await db.get(User, body.patient_id)
    if not patient or patient.role != "patient" or not patient.active:
        raise HTTPException(404, "Patient not found")
    token = secrets.token_urlsafe(32)
    binding = Binding(patient_id=patient.id, label=body.label, token_hash=digest(token))
    db.add(binding)
    await db.flush()
    connection = (
        await configure_connection(db, binding, endpoint, token) if endpoint else None
    )
    svc.audit(
        db,
        actor.id,
        patient.id,
        "mcp.binding_created",
        binding.id,
        request.state.request_id,
    )
    return {**binding_json(binding, connection), "token": token}


@app.get("/api/admin/mcp-bindings")
async def bindings(actor=Depends(admin), db=Depends(get_db)):
    connections = {
        c.binding_id: c for c in (await db.scalars(select(MCPConnection))).all()
    }
    return [
        binding_json(b, connections.get(b.id))
        for b in (await db.scalars(select(Binding).order_by(Binding.created_at))).all()
    ]


@app.put("/api/admin/mcp-bindings/{binding_id}/connection")
async def update_connection(
    binding_id: str,
    body: ConnectionInput,
    request: Request,
    actor=Depends(admin),
    db=Depends(get_db),
):
    endpoint = validate_endpoint(body.endpoint.get_secret_value())
    await lock_configurations(db)
    binding = await db.scalar(
        select(Binding).where(Binding.id == binding_id).with_for_update()
    )
    if not binding:
        raise HTTPException(404, "Binding not found")
    if not binding.active:
        raise HTTPException(409, "Binding has been revoked")
    patient = await db.get(User, binding.patient_id)
    if not patient or patient.role != "patient" or not patient.active:
        raise HTTPException(409, "Patient account unavailable")
    token = secrets.token_urlsafe(32)
    binding.token_hash = digest(token)
    connection = await configure_connection(db, binding, endpoint, token)
    svc.audit(
        db,
        actor.id,
        binding.patient_id,
        "mcp.connection_configured",
        binding.id,
        request.state.request_id,
    )
    return binding_json(binding, connection)


@app.delete("/api/admin/mcp-bindings/{binding_id}/connection")
async def disconnect_connection(
    binding_id: str, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    await lock_configurations(db)
    binding = await db.scalar(
        select(Binding).where(Binding.id == binding_id).with_for_update()
    )
    if not binding:
        raise HTTPException(404, "Binding not found")
    connection = await db.get(MCPConnection, binding.id)
    if connection is not None:
        await db.delete(connection)
    # Invalidates any in-flight connector requests using the previous token.
    binding.token_hash = digest(secrets.token_urlsafe(32))
    svc.audit(
        db,
        actor.id,
        binding.patient_id,
        "mcp.connection_disconnected",
        binding.id,
        request.state.request_id,
    )
    return binding_json(binding)


@app.post("/api/admin/mcp-bindings/{binding_id}/revoke")
async def revoke_binding(
    binding_id: str, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    await lock_configurations(db)
    binding = await db.scalar(
        select(Binding).where(Binding.id == binding_id).with_for_update()
    )
    if not binding:
        raise HTTPException(404, "Binding not found")
    binding.active = False
    connection = await db.get(MCPConnection, binding.id)
    if connection is not None:
        await db.delete(connection)
    svc.audit(
        db,
        actor.id,
        binding.patient_id,
        "mcp.binding_revoked",
        binding.id,
        request.state.request_id,
    )
    return binding_json(binding)


@app.get("/api/admin/notifications")
async def admin_notifications(actor=Depends(admin), db=Depends(get_db)):
    return [
        notification_json(n)
        for n in (
            await db.scalars(
                select(Notification).order_by(Notification.created_at.desc()).limit(200)
            )
        ).all()
    ]


@app.post("/api/admin/notifications/{notification_id}/retry")
async def retry(
    notification_id: str, request: Request, actor=Depends(admin), db=Depends(get_db)
):
    item = await db.get(Notification, notification_id, with_for_update=True)
    if not item:
        raise HTTPException(404, "Notification not found")
    if item.status not in {"failed", "retrying"}:
        raise HTTPException(409, "Only failed deliveries can be retried")
    item.status, item.next_attempt_at, item.attempts = "queued", utcnow(), 0
    svc.audit(
        db,
        actor.id,
        item.patient_id,
        "notification.retry",
        item.id,
        request.state.request_id,
    )
    return notification_json(item)


@app.get("/api/admin/audit")
async def audits(actor=Depends(admin), db=Depends(get_db)):
    rows = (
        await db.scalars(select(Audit).order_by(Audit.created_at.desc()).limit(500))
    ).all()
    return [
        {
            "id": a.id,
            "action": a.action,
            "actor_id": a.actor_id,
            "patient_id": a.patient_id,
            "object_id": a.object_id,
            "request_id": a.request_id,
            "created_at": a.created_at,
            "detail": a.detail,
        }
        for a in rows
    ]


@app.get("/api/admin/overview")
async def overview(actor=Depends(admin), db=Depends(get_db)):
    async def count(model, *conditions):
        return await db.scalar(
            select(func.count()).select_from(model).where(*conditions)
        )

    return {
        "patients": await count(User, User.role == "patient"),
        "devices": await count(Device, Device.active),
        "pending_doses": await count(Dose, Dose.status == "pending"),
        "unconfirmed_doses": await count(Dose, Dose.status == "unconfirmed"),
        "notifications_failed": await count(
            Notification, Notification.status == "failed"
        ),
        "mcp_bindings": await count(Binding, Binding.active),
    }


@app.get("/api/admin/status")
async def status(actor=Depends(admin), db=Depends(get_db)):
    worker = await db.get(WorkerState, "main")
    return {
        "environment": settings.environment,
        "auth_mode": "password_registration_and_operator_otp",
        "notification_channel": "webhook" if settings.notification_webhook else "inbox",
        "external_push": "configured"
        if settings.notification_webhook
        else "not_configured",
        "worker": {
            "heartbeat": worker.heartbeat if worker else None,
            "healthy": bool(
                worker and (utcnow() - worker.heartbeat).total_seconds() < 90
            ),
        },
        "mcp_bindings": await db.scalar(
            select(func.count()).select_from(Binding).where(Binding.active)
        ),
    }


@app.get("/health")
async def health():
    return {"status": "ok", "service": "wakemate", "version": "1.0.0"}


@app.get("/health/ready")
async def ready(db=Depends(get_db)):
    await db.execute(text("SELECT 1 FROM alembic_version"))
    return {"status": "ready"}


static = Path(__file__).parent.parent / "static"
if static.exists():
    app.mount("/assets", StaticFiles(directory=static), name="assets")


@app.get("/admin", include_in_schema=False)
async def admin_page():
    return FileResponse(static / "index.html")


@app.get("/", include_in_schema=False)
async def root():
    return RedirectResponse("/admin")
