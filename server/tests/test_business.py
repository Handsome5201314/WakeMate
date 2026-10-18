from __future__ import annotations

import asyncio
import contextlib
import uuid
from datetime import datetime, timedelta, timezone

import httpx
from sqlalchemy import select, text


def _idempotent(headers: dict[str, str], key: str | None = None) -> dict[str, str]:
    return {**headers, "Idempotency-Key": key or uuid.uuid4().hex}


async def _plan(client: httpx.AsyncClient, actor, *, times=None, plan_timezone=None):
    body = {
        "drug_name": "Test medication",
        "dosage": "1 tablet",
        "times": times or ["00:00", "00:01"],
        "note": "Test plan",
        "color": "#2C4A7E",
    }
    if plan_timezone:
        body["timezone"] = plan_timezone
    response = await client.post(
        "/api/plans",
        headers=actor["headers"],
        json=body,
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _doses(client: httpx.AsyncClient, actor, date=None):
    response = await client.get(
        "/api/doses",
        headers=actor["headers"],
        params={"date": date or datetime.now(timezone.utc).date().isoformat()},
    )
    assert response.status_code == 200, response.text
    assert isinstance(response.json(), list)
    return response.json()


async def _records(client: httpx.AsyncClient, actor):
    response = await client.get("/api/records", headers=actor["headers"])
    assert response.status_code == 200, response.text
    assert isinstance(response.json(), list)
    return response.json()


async def _confirm(client: httpx.AsyncClient, actor, dose_id, key=None):
    return await client.post(
        "/api/records/confirm",
        headers=_idempotent(actor["headers"], key),
        json={"dose_instance_id": dose_id, "confirmed_by": "user_tap"},
    )


async def _grant(client, patient, caregiver):
    invitation = await client.post(
        "/api/grants",
        headers=patient["headers"],
        json={"caregiver_id": caregiver["id"]},
    )
    assert invitation.status_code == 201, invitation.text
    grant_id = invitation.json()["id"]
    accepted = await client.post(
        f"/api/grants/{grant_id}/accept", headers=caregiver["headers"]
    )
    assert accepted.status_code == 200, accepted.text
    activated = await client.post(
        f"/api/grants/{grant_id}/activate", headers=patient["headers"]
    )
    assert activated.status_code == 200, activated.text
    return grant_id


async def _device(client, patient, admin_headers):
    device_sn = "TEST-" + uuid.uuid4().hex
    provisioned = await client.post(
        "/api/admin/devices",
        headers=admin_headers,
        json={"device_sn": device_sn, "device_type": "clasp_bead", "bead_total": 7},
    )
    assert provisioned.status_code == 201, provisioned.text
    device = provisioned.json()
    bound = await client.post(
        "/api/device/bind",
        headers=patient["headers"],
        json={"device_sn": device_sn, "claim_code": device["claim_code"]},
    )
    assert bound.status_code == 200, bound.text
    return device, {"Authorization": "Bearer " + device["device_token"]}


async def test_authentication_and_app_response_contracts(client, actors):
    unauthenticated = await client.get("/api/plans")
    assert unauthenticated.status_code in (401, 403)
    wrong_password = await client.post(
        "/api/auth/password",
        json={"username": actors["patient"]["phone"], "password": "incorrect-password"},
    )
    assert wrong_password.status_code == 401
    actor = actors["patient"]
    for endpoint in ("/api/plans", "/api/records", "/api/records/stats", "/api/device"):
        response = await client.get(endpoint, headers=actor["headers"])
        assert response.status_code == 200, response.text
        assert isinstance(response.json(), list)
    settings = await client.get("/api/settings", headers=actor["headers"])
    assert settings.status_code == 200, settings.text
    assert {
        "family_push_enabled",
        "quiet_start",
        "quiet_end",
        "daily_push_limit",
        "snooze_minutes",
        "max_snooze_count",
    } <= settings.json().keys()


async def test_plan_persistence_and_patient_isolation(client, actors):
    owner, outsider = actors["patient"], actors["other_patient"]
    plan = await _plan(client, owner)
    assert plan["synced_to_hw"] is False
    own_list = await client.get("/api/plans", headers=owner["headers"])
    assert [item["id"] for item in own_list.json()] == [plan["id"]]
    other_list = await client.get("/api/plans", headers=outsider["headers"])
    assert other_list.json() == []
    update = await client.put(
        "/api/plans/" + plan["id"],
        headers=outsider["headers"],
        json={
            "drug_name": "Unauthorized change",
            "dosage": "2 tablets",
            "times": ["09:00"],
        },
    )
    assert update.status_code in (403, 404)
    delete = await client.delete(
        "/api/plans/" + plan["id"], headers=outsider["headers"]
    )
    assert delete.status_code in (403, 404)
    unchanged = await client.get("/api/plans", headers=owner["headers"])
    assert unchanged.json()[0]["drug_name"] == "Test medication"


async def test_dose_identity_is_stable_and_confirmation_is_idempotent(client, actors):
    actor = actors["patient"]
    await _plan(client, actor)
    doses = await _doses(client, actor)
    repeated = await _doses(client, actor)
    assert len(doses) == 2
    assert {dose["id"] for dose in doses} == {dose["id"] for dose in repeated}
    assert all(dose["id"] == dose["dose_instance_id"] for dose in doses)
    target = doses[0]["id"]
    key = uuid.uuid4().hex
    first = await _confirm(client, actor, target, key)
    replay = await _confirm(client, actor, target, key)
    second_key = await _confirm(client, actor, target)
    assert first.status_code == replay.status_code == second_key.status_code == 200
    assert first.json() == replay.json()
    current = {dose["id"]: dose for dose in await _doses(client, actor)}
    assert current[target]["status"] == "confirmed"
    records = await _records(client, actor)
    matching = [record for record in records if record["id"] == target]
    assert len(matching) == 1
    assert matching[0]["status"] == "confirmed"
    conflicting = await _confirm(client, actor, doses[1]["id"], key)
    assert conflicting.status_code == 409


async def test_confirmation_rejects_missing_idempotency_and_foreign_dose(
    client, actors
):
    owner, outsider = actors["patient"], actors["other_patient"]
    await _plan(client, owner)
    target = (await _doses(client, owner))[0]["id"]
    missing_key = await client.post(
        "/api/records/confirm",
        headers=owner["headers"],
        json={"dose_instance_id": target, "confirmed_by": "user_tap"},
    )
    assert missing_key.status_code in (400, 422, 428)
    foreign = await _confirm(client, outsider, target)
    assert foreign.status_code in (403, 404)
    assert (await _doses(client, owner))[0]["status"] == "pending"


async def test_admin_cannot_confirm_for_a_patient(client, actors, admin_headers):
    actor = actors["patient"]
    await _plan(client, actor)
    target = (await _doses(client, actor))[0]["id"]
    response = await client.post(
        "/api/records/confirm",
        headers=_idempotent(admin_headers),
        json={"dose_instance_id": target, "confirmed_by": "user_tap"},
    )
    assert response.status_code in (403, 404)
    assert (await _doses(client, actor))[0]["status"] == "pending"


async def test_correction_keeps_history_and_reason_in_audit(
    client, actors, admin_headers
):
    actor = actors["patient"]
    await _plan(client, actor)
    target = (await _doses(client, actor))[0]["id"]
    assert (await _confirm(client, actor, target)).status_code == 200
    reason = "Accidental tap; patient requests correction"
    corrected = await client.post(
        f"/api/records/{target}/corrections",
        headers=_idempotent(actor["headers"]),
        json={"status": "pending", "reason": reason},
    )
    assert corrected.status_code == 200, corrected.text
    current = {dose["id"]: dose for dose in await _doses(client, actor)}
    assert current[target]["status"] == "pending"
    audit = await client.get("/api/admin/audit", headers=admin_headers)
    assert audit.status_code == 200, audit.text
    events = [event for event in audit.json() if event["object_id"] == target]
    assert len(events) >= 2
    assert any(reason in str(event["detail"]) for event in events)
    assert all(event["patient_id"] == actor["id"] for event in events)
    outsider = await client.post(
        f"/api/records/{target}/corrections",
        headers=_idempotent(actors["other_patient"]["headers"]),
        json={"status": "confirmed", "reason": "Unauthorized correction"},
    )
    assert outsider.status_code in (403, 404)


async def test_caregiver_access_requires_activation_and_revocation_is_immediate(
    client, actors
):
    patient, caregiver = actors["patient"], actors["caregiver"]
    await _plan(client, patient)
    endpoint = f"/api/patients/{patient['id']}/plans"
    before = await client.get(endpoint, headers=caregiver["headers"])
    assert before.status_code in (403, 404)
    invitation = await client.post(
        "/api/grants",
        headers=patient["headers"],
        json={"caregiver_id": caregiver["id"]},
    )
    assert invitation.status_code in (200, 201), invitation.text
    grant_id = invitation.json()["id"]
    accepted = await client.post(
        f"/api/grants/{grant_id}/accept", headers=caregiver["headers"]
    )
    assert accepted.status_code == 200, accepted.text
    not_activated = await client.get(endpoint, headers=caregiver["headers"])
    assert not_activated.status_code in (403, 404)
    activated = await client.post(
        f"/api/grants/{grant_id}/activate", headers=patient["headers"]
    )
    assert activated.status_code == 200, activated.text
    allowed = await client.get(endpoint, headers=caregiver["headers"])
    assert allowed.status_code == 200
    assert len(allowed.json()) == 1
    foreign = await client.get(
        f"/api/patients/{actors['other_patient']['id']}/plans",
        headers=caregiver["headers"],
    )
    assert foreign.status_code in (403, 404)
    revoked = await client.post(
        f"/api/grants/{grant_id}/revoke", headers=patient["headers"]
    )
    assert revoked.status_code == 200, revoked.text
    after = await client.get(endpoint, headers=caregiver["headers"])
    assert after.status_code in (403, 404)


async def test_expired_grant_cannot_be_used(client, actors):
    patient, caregiver = actors["patient"], actors["caregiver"]
    response = await client.post(
        "/api/grants",
        headers=patient["headers"],
        json={
            "caregiver_id": caregiver["id"],
            "expires_at": (
                datetime.now(timezone.utc) - timedelta(minutes=1)
            ).isoformat(),
        },
    )
    if response.status_code in (400, 422):
        return
    assert response.status_code in (200, 201), response.text
    grant_id = response.json()["id"]
    await client.post(f"/api/grants/{grant_id}/accept", headers=caregiver["headers"])
    await client.post(f"/api/grants/{grant_id}/activate", headers=patient["headers"])
    denied = await client.get(
        f"/api/patients/{patient['id']}/doses", headers=caregiver["headers"]
    )
    assert denied.status_code in (403, 404)


async def test_device_open_is_evidence_and_duplicate_event_is_not_recounted(
    client, actors, admin_headers
):
    patient = actors["patient"]
    await _plan(client, patient)
    target = (await _doses(client, patient))[0]["id"]
    _, device_headers = await _device(client, patient, admin_headers)
    event = {
        "event_id": uuid.uuid4().hex,
        "kind": "lid_open",
        "occurred_at": datetime.now(timezone.utc).isoformat(),
        "dose_instance_id": target,
    }
    first = await client.post("/api/device/events", headers=device_headers, json=event)
    duplicate = await client.post(
        "/api/device/events", headers=device_headers, json=event
    )
    assert first.status_code == duplicate.status_code == 200
    current = {dose["id"]: dose for dose in await _doses(client, patient)}
    assert current[target]["status"] == "pending"
    assert current[target]["evidence_count"] == 1
    event["event_id"] = uuid.uuid4().hex
    await _plan(client, actors["other_patient"])
    event["dose_instance_id"] = (await _doses(client, actors["other_patient"]))[0]["id"]
    foreign = await client.post(
        "/api/device/events", headers=device_headers, json=event
    )
    assert foreign.status_code in (403, 404)


async def test_worker_marks_unconfirmed_without_inventing_medication_results(
    client, actors, database
):
    from app.worker import run_once

    actor = actors["patient"]
    await _plan(client, actor)
    date = datetime.now(timezone.utc).date().isoformat()
    initial = await _doses(client, actor, date)
    now = datetime.now(timezone.utc) + timedelta(days=2)
    async with database() as session:
        await run_once(session, now=now)
        await session.commit()
    current = {dose["id"]: dose for dose in await _doses(client, actor, date)}
    assert {current[dose["id"]]["status"] for dose in initial} == {"unconfirmed"}
    records = await _records(client, actor)
    assert all(
        record.get("result") not in ("ontime", "late", "missed") for record in records
    )
    assert all(not record.get("actual_time") for record in records)


async def test_mcp_binding_selects_one_patient_and_revocation_takes_effect(
    client, actors, admin_headers
):
    patient, outsider = actors["patient"], actors["other_patient"]
    owned_plan = await _plan(client, patient)
    foreign_plan = await _plan(client, outsider)
    owned_doses = await _doses(client, patient)
    foreign_dose = (await _doses(client, outsider))[0]["id"]
    response = await client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": patient["id"], "label": "Test Xiaozhi binding"},
    )
    assert response.status_code in (200, 201), response.text
    binding = response.json()
    headers = {"Authorization": "Bearer " + binding["token"]}
    plans = await client.post(
        "/api/mcp/tools/get_medication_plans", headers=headers, json={}
    )
    assert plans.status_code == 200, plans.text
    returned_ids = {plan["id"] for plan in plans.json()["plans"]}
    assert returned_ids == {owned_plan["id"]}
    assert foreign_plan["id"] not in returned_ids
    doses = await client.post(
        "/api/mcp/tools/get_today_doses", headers=headers, json={}
    )
    assert doses.status_code == 200, doses.text
    assert {dose["id"] for dose in doses.json()["doses"]} == {
        dose["id"] for dose in owned_doses
    }
    attempted_override = await client.post(
        "/api/mcp/tools/get_medication_plans",
        headers=headers,
        json={"patient_id": outsider["id"]},
    )
    assert attempted_override.status_code in (400, 403, 422)
    foreign = await client.post(
        "/api/mcp/tools/get_dose_status",
        headers=headers,
        json={"dose_instance_id": foreign_dose},
    )
    assert foreign.status_code in (403, 404)
    write = await client.post("/api/mcp/tools/confirm_dose", headers=headers, json={})
    assert write.status_code in (403, 404)
    revoked = await client.post(
        f"/api/admin/mcp-bindings/{binding['id']}/revoke", headers=admin_headers
    )
    assert revoked.status_code == 200, revoked.text
    after = await client.post(
        "/api/mcp/tools/get_today_doses", headers=headers, json={}
    )
    assert after.status_code in (401, 403)


async def test_confirmation_receipt_cannot_overwrite_a_later_correction(client, actors):
    actor = actors["patient"]
    await _plan(client, actor)
    target = (await _doses(client, actor))[0]["id"]
    assert (await _confirm(client, actor, target)).status_code == 200
    duplicate_key = uuid.uuid4().hex
    duplicate = await _confirm(client, actor, target, duplicate_key)
    assert duplicate.status_code == 200, duplicate.text
    corrected = await client.post(
        f"/api/records/{target}/corrections",
        headers=_idempotent(actor["headers"]),
        json={
            "status": "pending",
            "reason": "Patient corrects an accidental confirmation",
        },
    )
    assert corrected.status_code == 200, corrected.text
    replayed = await _confirm(client, actor, target, duplicate_key)
    assert replayed.status_code == 200, replayed.text
    assert replayed.json() == duplicate.json()
    current = {dose["id"]: dose for dose in await _doses(client, actor)}
    assert current[target]["status"] == "pending"
    assert current[target]["actual_time"] is None
    assert current[target]["result"] is None


async def test_otp_expiry_single_use_and_guess_limit(client, actors, database):
    from app.cli import issue_otp
    from app.models import OTP, utcnow

    phone = actors["patient"]["phone"]
    async with database() as session:
        first_code = await issue_otp(session, phone)
        await session.commit()
    logged_in = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": first_code}
    )
    assert logged_in.status_code == 200, logged_in.text
    reused = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": first_code}
    )
    assert reused.status_code == 401

    async with database() as session:
        expired_code = await issue_otp(session, phone)
        await session.flush()
        challenge = await session.scalar(
            select(OTP).where(OTP.phone == phone, OTP.used.is_(False))
        )
        challenge.expires_at = utcnow() - timedelta(seconds=1)
        await session.commit()
    expired = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": expired_code}
    )
    assert expired.status_code == 401

    async with database() as session:
        protected_code = await issue_otp(session, phone)
        await session.commit()
    wrong_code = "000000" if protected_code != "000000" else "999999"
    for _ in range(5):
        wrong = await client.post(
            "/api/auth/login", json={"phone": phone, "otp": wrong_code}
        )
        assert wrong.status_code == 401
    locked = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": protected_code}
    )
    assert locked.status_code == 401
    async with database() as session:
        challenge = await session.scalar(
            select(OTP).where(OTP.phone == phone, OTP.used.is_(False))
        )
        assert challenge.attempts == 5
    sms = await client.post("/api/auth/otp", json={"phone": phone})
    assert sms.status_code == 503


async def test_otp_request_rate_is_limited(client, actors):
    phone = actors["patient"]["phone"]
    for _ in range(10):
        response = await client.post(
            "/api/auth/login", json={"phone": phone, "otp": "000000"}
        )
        assert response.status_code == 401
    blocked = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": "000000"}
    )
    assert blocked.status_code == 429


async def test_plan_update_preserves_past_doses_and_cancels_old_future_version(
    client, actors, monkeypatch
):
    from app import main, services

    actor = actors["patient"]
    now = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    monkeypatch.setattr(main, "utcnow", lambda: now)
    monkeypatch.setattr(services, "utcnow", lambda: now)
    plan = await _plan(client, actor, times=["00:00", "23:59"])
    original = await _doses(client, actor, now.date().isoformat())
    past = next(
        dose
        for dose in original
        if dose["scheduled_time"].startswith(now.date().isoformat() + "T00:00")
    )
    future = next(dose for dose in original if dose["id"] != past["id"])
    assert (await _confirm(client, actor, past["id"])).status_code == 200
    updated = await client.put(
        "/api/plans/" + plan["id"],
        headers=actor["headers"],
        json={
            "drug_name": "Updated medication",
            "dosage": "2 tablets",
            "times": ["00:00", "23:58"],
        },
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["version"] == plan["version"] + 1
    current = {
        dose["id"]: dose for dose in await _doses(client, actor, now.date().isoformat())
    }
    assert current[past["id"]]["status"] == "confirmed"
    assert current[past["id"]]["dosage"] == "1 tablet"
    assert current[past["id"]]["drug_name"] == "Test medication"
    assert current[future["id"]]["status"] == "cancelled"
    replacement = [
        dose
        for dose in current.values()
        if dose["plan_version"] == updated.json()["version"]
    ]
    assert len(replacement) == 1
    assert replacement[0]["scheduled_time"].startswith(
        now.date().isoformat() + "T23:58"
    )
    assert replacement[0]["dosage"] == "2 tablets"
    tomorrow = (now + timedelta(days=1)).date().isoformat()
    following_day = await _doses(client, actor, tomorrow)
    assert len(following_day) == 2
    assert all(
        dose["plan_version"] == updated.json()["version"] for dose in following_day
    )


async def test_patient_day_collects_plan_doses_across_plan_timezone_dates(
    client, actors
):
    actor = actors["patient"]
    profile = await client.put(
        "/api/settings/profile",
        headers=actor["headers"],
        json={"timezone": "America/Los_Angeles"},
    )
    assert profile.status_code == 200, profile.text
    plan = await _plan(
        client, actor, times=["08:00", "20:00"], plan_timezone="Asia/Tokyo"
    )
    doses = await _doses(client, actor, "2026-10-12")
    scheduled = {
        datetime.fromisoformat(dose["scheduled_time"]).astimezone(timezone.utc)
        for dose in doses
        if dose["plan_id"] == plan["id"]
    }
    assert scheduled == {
        datetime(2026, 10, 12, 11, 0, tzinfo=timezone.utc),
        datetime(2026, 10, 12, 23, 0, tzinfo=timezone.utc),
    }
    repeated = await _doses(client, actor, "2026-10-12")
    assert {dose["id"] for dose in repeated} == {dose["id"] for dose in doses}


async def test_revoked_grant_blocks_queued_family_delivery(
    client, actors, admin_headers, database
):
    from app.worker import run_once

    patient, caregiver = actors["patient"], actors["caregiver"]
    grant_id = await _grant(client, patient, caregiver)
    await _plan(client, patient)
    target = (await _doses(client, patient))[0]["id"]
    assert (await _confirm(client, patient, target)).status_code == 200
    before = await client.get("/api/admin/notifications", headers=admin_headers)
    matching = [item for item in before.json() if item["target_id"] == caregiver["id"]]
    assert len(matching) == 1
    assert matching[0]["status"] == "queued"
    revoked = await client.post(
        f"/api/grants/{grant_id}/revoke", headers=patient["headers"]
    )
    assert revoked.status_code == 200, revoked.text
    async with database() as session:
        await run_once(session, now=datetime.now(timezone.utc) + timedelta(seconds=1))
        await session.commit()
    after = await client.get("/api/admin/notifications", headers=admin_headers)
    matching = [item for item in after.json() if item["target_id"] == caregiver["id"]]
    assert matching[0]["status"] == "cancelled"
    assert matching[0]["attempts"] == 0
    inbox = await client.get("/api/notifications", headers=caregiver["headers"])
    assert inbox.status_code == 200
    assert inbox.json() == []


async def test_plan_sync_requires_ack_of_current_version(client, actors, admin_headers):
    actor = actors["patient"]
    plan = await _plan(client, actor)
    _, device_headers = await _device(client, actor, admin_headers)
    snapshot = await client.get("/api/device/plans", headers=device_headers)
    assert snapshot.status_code == 200, snapshot.text
    assert snapshot.json()[0]["synced_to_hw"] is False
    before_ack = await client.get("/api/plans", headers=actor["headers"])
    assert before_ack.json()[0]["synced_to_hw"] is False
    acknowledged = await client.post(
        "/api/device/ack",
        headers=device_headers,
        json={"plan_id": plan["id"], "version": plan["version"]},
    )
    assert acknowledged.status_code == 200, acknowledged.text
    after_ack = await client.get("/api/plans", headers=actor["headers"])
    assert after_ack.json()[0]["synced_to_hw"] is True
    updated = await client.put(
        "/api/plans/" + plan["id"],
        headers=actor["headers"],
        json={
            "drug_name": "Updated medication",
            "dosage": "2 tablets",
            "times": ["00:00"],
        },
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["synced_to_hw"] is False
    stale_ack = await client.post(
        "/api/device/ack",
        headers=device_headers,
        json={"plan_id": plan["id"], "version": plan["version"]},
    )
    assert stale_ack.status_code == 409
    assert (await client.get("/api/plans", headers=actor["headers"])).json()[0][
        "synced_to_hw"
    ] is False


async def test_commit_failure_returns_error_and_does_not_persist_a_plan(
    client, actors, database
):
    async with database() as session:
        await session.execute(
            text("CREATE TABLE test_commit_guard (patient_id varchar(36) PRIMARY KEY)")
        )
        await session.execute(
            text(
                "ALTER TABLE medication_plans ADD CONSTRAINT test_commit_guard_fk "
                "FOREIGN KEY (patient_id) REFERENCES test_commit_guard(patient_id) "
                "DEFERRABLE INITIALLY DEFERRED"
            )
        )
        await session.commit()
    response = await client.post(
        "/api/plans",
        headers=actors["patient"]["headers"],
        json={
            "drug_name": "Must not be saved",
            "dosage": "1 tablet",
            "times": ["00:00"],
        },
    )
    assert response.status_code >= 400, response.text
    persisted = await client.get("/api/plans", headers=actors["patient"]["headers"])
    assert persisted.status_code == 200
    assert persisted.json() == []


async def test_plan_update_waits_for_materialization_and_cancels_old_future_version(
    client, actors, database, monkeypatch
):
    from app import main, services
    from app.models import Dose

    actor = actors["patient"]
    now = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    monkeypatch.setattr(main, "utcnow", lambda: now)
    monkeypatch.setattr(services, "utcnow", lambda: now)
    plan = await _plan(client, actor, times=["08:00", "20:00"])
    tomorrow = (now + timedelta(days=1)).date()
    async with database() as holder:
        await services.lock_patient(holder, actor["id"])
        await services.materialize(holder, actor["id"], tomorrow)
        holder_pid = await holder.scalar(text("SELECT pg_backend_pid()"))
        update_task = asyncio.create_task(
            client.put(
                "/api/plans/" + plan["id"],
                headers=actor["headers"],
                json={
                    "drug_name": "Next plan version",
                    "dosage": "2 tablets",
                    "times": ["09:00", "21:00"],
                },
            )
        )

        async def wait_for_database_lock():
            async with database() as observer:
                while True:
                    blocked = await observer.scalar(
                        text(
                            "SELECT EXISTS (SELECT 1 FROM pg_locks "
                            "WHERE locktype = 'advisory' AND NOT granted "
                            "AND :holder_pid = ANY(pg_blocking_pids(pid)))"
                        ),
                        {"holder_pid": holder_pid},
                    )
                    if blocked:
                        return
                    if update_task.done():
                        raise AssertionError(
                            "Plan update completed without waiting for materialization"
                        )
                    await asyncio.sleep(0.025)

        try:
            await asyncio.wait_for(wait_for_database_lock(), timeout=5)
            assert not update_task.done()
            await holder.commit()
            updated = await asyncio.wait_for(update_task, timeout=5)
            assert updated.status_code == 200, updated.text
        finally:
            await holder.rollback()
            if not update_task.done():
                update_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await update_task

    await _doses(client, actor, tomorrow.isoformat())
    start = datetime.combine(tomorrow, datetime.min.time(), timezone.utc)
    async with database() as session:
        future_doses = (
            await session.scalars(
                select(Dose).where(
                    Dose.plan_id == plan["id"],
                    Dose.scheduled_time >= start,
                    Dose.scheduled_time < start + timedelta(days=1),
                )
            )
        ).all()
    old_version = [
        dose for dose in future_doses if dose.plan_version == plan["version"]
    ]
    new_version = [
        dose for dose in future_doses if dose.plan_version == updated.json()["version"]
    ]
    assert len(old_version) == len(new_version) == 2
    assert all(dose.status == "cancelled" for dose in old_version)
    assert all(
        dose.status == "pending" and dose.dosage == "2 tablets" for dose in new_version
    )
    assert all(
        dose.plan_version == updated.json()["version"]
        for dose in future_doses
        if dose.status == "pending"
    )
