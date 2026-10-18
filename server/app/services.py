import json
import secrets
from datetime import datetime, time, timedelta, timezone
from uuid import NAMESPACE_URL, uuid5
from zoneinfo import ZoneInfo

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert

from app.config import get_settings
from app.models import (
    Audit,
    Binding,
    Device,
    Dose,
    Evidence,
    Grant,
    Notification,
    Plan,
    User,
    utcnow,
)
from app.security import digest, hash_password

DEFAULT_SETTINGS = {
    "family_push_enabled": True,
    "quiet_start": "22:00",
    "quiet_end": "07:00",
    "daily_push_limit": 5,
    "snooze_minutes": 15,
    "max_snooze_count": 2,
}


async def ensure_admin(db):
    user = await db.scalar(select(User).where(User.username == "admin"))
    if user is None:
        user = User(
            username="admin",
            display_name="Local administrator",
            role="admin",
            password_hash=hash_password(get_settings().admin_password),
            settings=DEFAULT_SETTINGS,
        )
        db.add(user)
        await db.flush()
    return user


def audit(db, actor_id, patient_id, action, object_id, request_id, detail=None):
    db.add(
        Audit(
            actor_id=actor_id,
            patient_id=patient_id,
            action=action,
            object_id=object_id,
            request_id=request_id,
            detail=detail or {},
        )
    )


def require_patient(user):
    if user.role != "patient":
        raise HTTPException(403, "Only the patient can change medication facts")


async def patient_access(db, actor, patient_id, scope):
    patient = await db.get(User, patient_id)
    if not patient or patient.role != "patient" or not patient.active:
        raise HTTPException(404, "Patient not found")
    if actor.id == patient_id and actor.role == "patient":
        return patient
    grants = (
        await db.scalars(
            select(Grant).where(
                Grant.patient_id == patient_id,
                Grant.caregiver_id == actor.id,
                Grant.status == "active",
            )
        )
    ).all()
    if actor.role != "caregiver" or not any(
        scope in g.scopes and (g.expires_at is None or g.expires_at > utcnow())
        for g in grants
    ):
        raise HTTPException(403, "Active patient grant required")
    return patient


def user_json(user):
    return {
        "id": user.id,
        "username": user.username if user.username != user.phone else None,
        "display_name": user.display_name,
        "role": user.role,
        "phone_masked": (user.phone[:3] + "****" + user.phone[-4:])
        if user.phone
        else None,
        "timezone": user.timezone,
        "created_at": user.created_at,
    }


async def plan_json(db, plan):
    devices = (
        await db.scalars(
            select(Device).where(Device.patient_id == plan.patient_id, Device.active)
        )
    ).all()
    synced = bool(devices) and all(
        d.ack_versions.get(plan.id) == plan.version for d in devices
    )
    return {
        "id": plan.id,
        "drug_name": plan.drug_name,
        "dosage": plan.dosage,
        "times": plan.times,
        "note": plan.note,
        "color": plan.color,
        "active": plan.active,
        "created_at": plan.created_at,
        "version": plan.version,
        "timezone": plan.timezone,
        "synced_to_hw": synced,
        "sync_status": "acknowledged" if synced else "pending",
    }


async def list_plans(db, patient_id):
    plans = (
        await db.scalars(
            select(Plan)
            .where(Plan.patient_id == patient_id, Plan.deleted_at.is_(None))
            .order_by(Plan.created_at)
        )
    ).all()
    return [await plan_json(db, p) for p in plans]


async def lock_patient(db, patient_id):
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended("wakemate:patient:" + patient_id, 0)
            )
        )
    )


async def lock_phone(db, phone):
    # A row lock cannot protect a phone before its first account or OTP exists.
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended("wakemate:phone:" + digest(phone), 0)
            )
        )
    )


async def lock_username(db, username):
    # Serialize first-use registration before the unique username constraint is hit.
    await db.execute(
        select(
            func.pg_advisory_xact_lock(
                func.hashtextextended("wakemate:username:" + digest(username), 0)
            )
        )
    )


async def materialize(db, patient_id, local_date=None):
    await lock_patient(db, patient_id)
    patient = await db.get(User, patient_id)
    day = local_date or utcnow().astimezone(ZoneInfo(patient.timezone)).date()
    patient_zone = ZoneInfo(patient.timezone)
    start = datetime.combine(day, time.min, patient_zone).astimezone(timezone.utc)
    end = datetime.combine(day + timedelta(days=1), time.min, patient_zone).astimezone(
        timezone.utc
    )
    plans = (
        await db.scalars(
            select(Plan).where(
                Plan.patient_id == patient_id, Plan.active, Plan.deleted_at.is_(None)
            )
        )
    ).all()
    for plan in plans:
        zone = ZoneInfo(plan.timezone)
        plan_day = start.astimezone(zone).date()
        last_day = (end - timedelta(microseconds=1)).astimezone(zone).date()
        while plan_day <= last_day:
            for clock in plan.times:
                naive = datetime.combine(plan_day, time.fromisoformat(clock))
                scheduled = naive.replace(tzinfo=zone).astimezone(timezone.utc)
                if not start <= scheduled < end:
                    continue
                if plan.version > 1 and scheduled < plan.version_effective_at:
                    continue
                # Nonexistent DST times are skipped; ambiguous times use the first occurrence.
                if scheduled.astimezone(zone).replace(tzinfo=None) != naive:
                    continue
                dose_id = str(
                    uuid5(
                        NAMESPACE_URL,
                        f"wakemate:{plan.id}:{plan.version}:{scheduled.isoformat()}",
                    )
                )
                await db.execute(
                    insert(Dose)
                    .values(
                        id=dose_id,
                        patient_id=patient_id,
                        plan_id=plan.id,
                        plan_version=plan.version,
                        drug_name=plan.drug_name,
                        dosage=plan.dosage,
                        timezone=plan.timezone,
                        scheduled_time=scheduled,
                        status="pending",
                        created_at=utcnow(),
                    )
                    .on_conflict_do_nothing()
                )
            plan_day += timedelta(days=1)


async def dose_json(db, dose):
    evidence = (
        await db.scalars(
            select(Evidence)
            .where(Evidence.dose_id == dose.id)
            .order_by(Evidence.created_at)
        )
    ).all()
    return {
        "id": dose.id,
        "dose_instance_id": dose.id,
        "patient_id": dose.patient_id,
        "plan_id": dose.plan_id,
        "plan_version": dose.plan_version,
        "drug_name": dose.drug_name,
        "dosage": dose.dosage,
        "scheduled_time": dose.scheduled_time,
        "timezone": dose.timezone,
        "status": dose.status,
        "actual_time": dose.actual_time,
        "result": dose.result,
        "confirmed_by": dose.confirmed_by,
        "created_at": dose.created_at,
        "delay_seconds": int((dose.actual_time - dose.scheduled_time).total_seconds())
        if dose.actual_time
        else None,
        "sync_status": "server_saved",
        "evidence_count": len(evidence),
        "evidence": [
            {
                "id": e.id,
                "kind": e.kind,
                "actor_id": e.actor_id,
                "occurred_at": e.occurred_at,
                "received_at": e.created_at,
                "request_id": e.request_id,
                "detail": {k: v for k, v in e.detail.items() if k != "response"},
            }
            for e in evidence
        ],
    }


async def list_doses(db, patient_id, local_date=None):
    patient = await db.get(User, patient_id)
    day = local_date or utcnow().astimezone(ZoneInfo(patient.timezone)).date()
    await materialize(db, patient_id, day)
    zone = ZoneInfo(patient.timezone)
    start = datetime.combine(day, time.min, zone).astimezone(timezone.utc)
    end = datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(
        timezone.utc
    )
    doses = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.patient_id == patient_id,
                Dose.scheduled_time >= start,
                Dose.scheduled_time < end,
            )
            .order_by(Dose.scheduled_time)
        )
    ).all()
    return [await dose_json(db, d) for d in doses]


async def list_records(db, patient_id, days=7):
    doses = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.patient_id == patient_id,
                Dose.actual_time.is_not(None),
                Dose.scheduled_time >= utcnow() - timedelta(days=days),
            )
            .order_by(Dose.scheduled_time.desc())
        )
    ).all()
    return [await dose_json(db, d) for d in doses]


async def list_evidence_doses(db, patient_id, days=7):
    doses = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.patient_id == patient_id,
                select(Evidence.id)
                .where(
                    Evidence.dose_id == Dose.id,
                    Evidence.created_at >= utcnow() - timedelta(days=days),
                )
                .exists(),
            )
            .order_by(Dose.scheduled_time.desc())
        )
    ).all()
    return [await dose_json(db, d) for d in doses]


async def list_history(db, patient_id, days=7):
    now = utcnow()
    doses = (
        await db.scalars(
            select(Dose)
            .where(
                Dose.patient_id == patient_id,
                Dose.scheduled_time >= now - timedelta(days=days),
                Dose.scheduled_time <= now,
            )
            .order_by(Dose.scheduled_time.desc())
        )
    ).all()
    return [await dose_json(db, d) for d in doses]


async def stats(db, patient_id, days=30):
    patient = await db.get(User, patient_id)
    await materialize(db, patient_id)
    zone = ZoneInfo(patient.timezone)
    today = utcnow().astimezone(zone).date()
    first = today - timedelta(days=days - 1)
    start = datetime.combine(first, time.min, zone).astimezone(timezone.utc)
    doses = (
        await db.scalars(
            select(Dose).where(
                Dose.patient_id == patient_id,
                Dose.scheduled_time >= start,
                Dose.status != "cancelled",
            )
        )
    ).all()
    results = []
    streak = 0
    for offset in range(days):
        day = first + timedelta(days=offset)
        items = [d for d in doses if d.scheduled_time.astimezone(zone).date() == day]
        ontime = sum(d.result == "ontime" and d.status == "confirmed" for d in items)
        late = sum(d.result == "late" and d.status == "confirmed" for d in items)
        streak = streak + 1 if items and ontime + late == len(items) else 0
        results.append(
            {
                "date": day.isoformat(),
                "total": len(items),
                "ontime": ontime,
                "late": late,
                "missed": 0,
                "unconfirmed": sum(d.status == "unconfirmed" for d in items),
                "pending": sum(d.status == "pending" for d in items),
                "rate": round(100 * ontime / len(items), 1) if items else 0.0,
                "streak_days": streak,
            }
        )
    return results


async def resolve_dose(db, patient, body):
    if body.dose_instance_id:
        dose = await db.scalar(
            select(Dose)
            .where(Dose.id == body.dose_instance_id, Dose.patient_id == patient.id)
            .with_for_update()
        )
    elif body.plan_id and body.scheduled_time and body.reminder_id:
        plan = await db.get(Plan, body.plan_id)
        if (
            not plan
            or plan.patient_id != patient.id
            or plan.deleted_at
            or not plan.active
        ):
            raise HTTPException(404, "Plan not found")
        value = body.scheduled_time
        if value.tzinfo is None:
            value = value.replace(tzinfo=ZoneInfo(plan.timezone))
        scheduled = value.astimezone(timezone.utc)
        if abs((scheduled - utcnow()).total_seconds()) > 7 * 86400:
            raise HTTPException(422, "Confirmation time outside supported window")
        await materialize(
            db, patient.id, scheduled.astimezone(ZoneInfo(patient.timezone)).date()
        )
        dose = await db.scalar(
            select(Dose)
            .where(
                Dose.plan_id == plan.id,
                Dose.patient_id == patient.id,
                Dose.scheduled_time == scheduled,
                Dose.status != "cancelled",
            )
            .order_by(Dose.plan_version.desc())
            .limit(1)
            .with_for_update()
        )
    else:
        raise HTTPException(422, "dose_instance_id required")
    if not dose or dose.status == "cancelled":
        raise HTTPException(404, "Dose not found")
    return dose


async def add_notification(db, dose, target_id, event, now=None):
    now = now or utcnow()
    channel = "webhook" if get_settings().notification_webhook else "inbox"
    await db.execute(
        insert(Notification)
        .values(
            id=secrets.token_hex(16),
            created_at=now,
            patient_id=dose.patient_id,
            dose_id=dose.id,
            target_id=target_id,
            event=event,
            channel=channel,
            status="queued",
            attempts=0,
            next_attempt_at=now,
            payload={"dose_instance_id": dose.id, "event": event, "state": dose.status},
        )
        .on_conflict_do_nothing()
    )


async def family_notifications(db, dose, event, now=None):
    now = now or utcnow()
    patient = await db.get(User, dose.patient_id)
    if not {**DEFAULT_SETTINGS, **patient.settings}["family_push_enabled"]:
        return
    grants = (
        await db.scalars(
            select(Grant).where(
                Grant.patient_id == patient.id, Grant.status == "active"
            )
        )
    ).all()
    for grant in grants:
        if "reminders:read" in grant.scopes and (
            not grant.expires_at or grant.expires_at > now
        ):
            await add_notification(db, dose, grant.caregiver_id, event, now)


async def confirm(db, patient, body, key, request_id):
    require_patient(patient)
    dose = await resolve_dose(db, patient, body)
    key = key or ("legacy:" + dose.id if body.reminder_id else None)
    if not key or len(key) > 128:
        raise HTTPException(422, "Idempotency-Key required (1..128 characters)")
    payload_hash = digest(
        json.dumps({"dose": dose.id, "source": body.confirmed_by}, sort_keys=True)
    )
    prior = await db.scalar(
        select(Evidence).where(
            Evidence.patient_id == patient.id, Evidence.idempotency_key == key
        )
    )
    if prior:
        if prior.payload_hash != payload_hash:
            raise HTTPException(409, "Idempotency key reused for different operation")
        return prior.detail["response"]
    if dose.scheduled_time > utcnow() + timedelta(minutes=30):
        raise HTTPException(422, "Cannot confirm a future dose")
    if dose.status == "confirmed":
        response = {
            "message": "Already confirmed",
            "data": await dose_json(db, dose),
            "duplicate": True,
        }
        db.add(
            Evidence(
                patient_id=patient.id,
                dose_id=dose.id,
                actor_id=patient.id,
                kind="confirmation_receipt",
                occurred_at=utcnow(),
                request_id=request_id,
                idempotency_key=key,
                payload_hash=payload_hash,
                detail={
                    "response": json.loads(
                        json.dumps(response, default=lambda x: x.isoformat())
                    )
                },
            )
        )
        audit(
            db,
            patient.id,
            patient.id,
            "dose.duplicate_confirmation",
            dose.id,
            request_id,
        )
        return response
    now = utcnow()
    dose.status, dose.actual_time, dose.confirmed_by = (
        "confirmed",
        now,
        body.confirmed_by,
    )
    dose.result = (
        "ontime"
        if (now - dose.scheduled_time).total_seconds()
        <= get_settings().confirmation_window_seconds
        else "late"
    )
    evidence = Evidence(
        patient_id=patient.id,
        dose_id=dose.id,
        actor_id=patient.id,
        kind=body.confirmed_by,
        occurred_at=now,
        request_id=request_id,
        idempotency_key=key,
        payload_hash=payload_hash,
        detail={},
    )
    db.add(evidence)
    await db.flush()
    response = {
        "message": "Medication confirmation saved",
        "data": await dose_json(db, dose),
    }
    # Store the first response for replay; later corrections must not rewrite it.
    evidence.detail = {
        "response": json.loads(json.dumps(response, default=lambda x: x.isoformat()))
    }
    audit(db, patient.id, patient.id, "dose.confirmed", dose.id, request_id)
    await family_notifications(db, dose, "dose_confirmed")
    return response


async def correct(db, patient, dose_id, body, key, request_id):
    require_patient(patient)
    if not key or len(key) > 128:
        raise HTTPException(422, "Idempotency-Key required")
    dose = await db.scalar(
        select(Dose)
        .where(Dose.id == dose_id, Dose.patient_id == patient.id)
        .with_for_update()
    )
    if not dose or dose.status == "cancelled":
        raise HTTPException(404, "Dose not found")
    payload_hash = digest(
        json.dumps({"dose": dose_id, **body.model_dump()}, sort_keys=True)
    )
    prior = await db.scalar(
        select(Evidence).where(
            Evidence.patient_id == patient.id, Evidence.idempotency_key == key
        )
    )
    if prior:
        if prior.payload_hash != payload_hash:
            raise HTTPException(409, "Idempotency key conflict")
        return prior.detail["response"]
    now = utcnow()
    if body.status == "confirmed" and dose.scheduled_time > now + timedelta(minutes=30):
        raise HTTPException(422, "Cannot confirm a future dose")
    before = dose.status
    dose.status = body.status
    dose.actual_time = now if body.status == "confirmed" else None
    dose.confirmed_by = "user_correction" if body.status == "confirmed" else None
    dose.result = (
        (
            "ontime"
            if (now - dose.scheduled_time).total_seconds()
            <= get_settings().confirmation_window_seconds
            else "late"
        )
        if dose.actual_time
        else None
    )
    evidence = Evidence(
        patient_id=patient.id,
        dose_id=dose.id,
        actor_id=patient.id,
        kind="correction",
        occurred_at=now,
        request_id=request_id,
        idempotency_key=key,
        payload_hash=payload_hash,
        detail={"before": before, "after": body.status, "reason": body.reason},
    )
    db.add(evidence)
    await db.flush()
    response = {"message": "Correction appended", "data": await dose_json(db, dose)}
    evidence.detail = {
        **evidence.detail,
        "response": json.loads(json.dumps(response, default=lambda x: x.isoformat())),
    }
    audit(
        db,
        patient.id,
        patient.id,
        "dose.corrected",
        dose_id,
        request_id,
        {"reason": body.reason},
    )
    return response


def grant_json(grant):
    return {
        "id": grant.id,
        "patient_id": grant.patient_id,
        "caregiver_id": grant.caregiver_id,
        "status": "expired"
        if grant.expires_at
        and grant.expires_at <= utcnow()
        and grant.status == "active"
        else grant.status,
        "scopes": grant.scopes,
        "expires_at": grant.expires_at,
        "created_at": grant.created_at,
    }


def device_json(device):
    online = (
        device.last_sync_at and (utcnow() - device.last_sync_at).total_seconds() < 120
    )
    return {
        "id": device.id,
        "patient_id": device.patient_id,
        "device_sn": device.device_sn,
        "device_type": device.device_type,
        "firmware_ver": device.firmware_ver,
        "bead_total": device.bead_total,
        "last_sync_at": device.last_sync_at,
        "state": {**device.state, "status": "online" if online else "offline"},
        "sensor_capability": "not_verified",
        "active": device.active,
    }


async def list_devices(db, patient_id):
    devices = (
        await db.scalars(
            select(Device).where(Device.patient_id == patient_id, Device.active)
        )
    ).all()
    return [device_json(d) for d in devices]


async def mcp_call(db, token, name, args, request_id):
    binding = await db.scalar(
        select(Binding).where(Binding.token_hash == digest(token), Binding.active)
    )
    if not binding:
        raise HTTPException(401, "Active MCP binding required")
    patient = await db.get(User, binding.patient_id)
    if not patient or not patient.active or patient.role != "patient":
        raise HTTPException(403, "Binding patient unavailable")
    allowed = {
        "get_today_doses": set(),
        "get_medication_plans": set(),
        "get_device_status": set(),
        "get_dose_status": {"dose_instance_id"},
        "get_recent_medication_history": {"days"},
    }
    if name not in allowed or set(args) - allowed[name]:
        raise HTTPException(422, "Unknown tool or unsupported arguments")
    if name == "get_today_doses":
        value = {"doses": await list_doses(db, patient.id)}
    elif name == "get_medication_plans":
        value = {"plans": await list_plans(db, patient.id)}
    elif name == "get_device_status":
        value = {"devices": await list_devices(db, patient.id)}
    elif name == "get_recent_medication_history":
        days = args.get("days", 7)
        if type(days) is not int or not 1 <= days <= 90:
            raise HTTPException(422, "days must be an integer in 1..90")
        value = {"records": await list_history(db, patient.id, days)}
    else:
        dose = await db.scalar(
            select(Dose).where(
                Dose.id == args.get("dose_instance_id"), Dose.patient_id == patient.id
            )
        )
        if not dose:
            raise HTTPException(404, "Dose not found in binding")
        value = {"dose": await dose_json(db, dose)}
    binding.last_called_at = utcnow()
    audit(db, binding.id, patient.id, "mcp." + name, binding.id, request_id)
    return value
