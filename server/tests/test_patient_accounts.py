import asyncio
import json
from datetime import timedelta

import pytest
from sqlalchemy import func, select

from app.cli import issue_otp
from app.main import settings
from app.models import Audit, Binding, Grant, OTP, Plan, User
from app.security import digest, verify_password


async def _new_otp(database, phone):
    async with database() as db:
        code = await issue_otp(db, phone)
        await db.commit()
    return code


async def _user(database, phone):
    async with database() as db:
        return await db.scalar(select(User).where(User.phone == phone))


@pytest.mark.asyncio
async def test_first_otp_login_creates_patient_and_reuses_id(
    client, database, admin_headers
):
    phone = "138" + "12345678"
    code = await _new_otp(database, phone)
    first = await client.post("/api/auth/login", json={"phone": phone, "otp": code})
    assert first.status_code == 200, first.text
    first_id = first.json()["user_id"]
    user = await _user(database, phone)
    assert user.id == first_id
    assert user.username == phone
    assert user.role == "patient"
    assert user.display_name == "用户5678"
    assert user.timezone == "Asia/Shanghai"
    assert user.active is True
    assert not verify_password(phone, user.password_hash)
    listed = await client.get("/api/admin/patients", headers=admin_headers)
    assert listed.status_code == 200
    assert [row["id"] for row in listed.json()] == [first_id]
    assert listed.json()[0]["phone_masked"] == "138****5678"
    assert listed.json()[0]["username"] is None
    assert phone not in json.dumps(listed.json())
    assert "phone" not in listed.json()[0]

    second_code = await _new_otp(database, phone)
    second = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": second_code}
    )
    assert second.status_code == 200, second.text
    assert second.json()["user_id"] == first_id
    replay = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": second_code}
    )
    assert replay.status_code == 401

    async with database() as db:
        assert (
            await db.scalar(select(func.count(User.id)).where(User.phone == phone)) == 1
        )
        created = (
            await db.scalars(select(Audit).where(Audit.action == "account.created"))
        ).all()
        assert len(created) == 1
        assert created[0].actor_id == created[0].patient_id == first_id
        assert created[0].detail == {"source": "app_otp"}
        assert phone not in json.dumps(created[0].detail)


@pytest.mark.asyncio
async def test_invalid_or_expired_otp_does_not_create_account(client, database):
    phone = "139" + "23456789"
    code = await _new_otp(database, phone)
    invalid = await client.post(
        "/api/auth/login",
        json={"phone": phone, "otp": "000000" if code != "000000" else "999999"},
    )
    assert invalid.status_code == 401
    assert await _user(database, phone) is None

    expired_code = await _new_otp(database, phone)
    async with database() as db:
        challenge = await db.scalar(
            select(OTP).where(OTP.phone == phone, OTP.used.is_(False))
        )
        challenge.expires_at = challenge.expires_at - timedelta(minutes=10)
        await db.commit()
    expired = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": expired_code}
    )
    assert expired.status_code == 401
    assert await _user(database, phone) is None


@pytest.mark.asyncio
async def test_stopped_account_cannot_be_revived(client, database):
    phone = "137" + "34567890"
    code = await _new_otp(database, phone)
    login = await client.post("/api/auth/login", json={"phone": phone, "otp": code})
    assert login.status_code == 200
    patient_id = login.json()["user_id"]
    outstanding_code = await _new_otp(database, phone)
    async with database() as db:
        user = await db.get(User, patient_id)
        user.active = False
        await db.commit()

    blocked = await client.post(
        "/api/auth/login", json={"phone": phone, "otp": outstanding_code}
    )
    assert blocked.status_code == 401
    user = await _user(database, phone)
    assert user.id == patient_id
    assert not user.active
    async with database() as db:
        with pytest.raises(ValueError, match="Account unavailable"):
            await issue_otp(db, phone)
        assert (
            await db.scalar(select(func.count(User.id)).where(User.phone == phone)) == 1
        )


@pytest.mark.asyncio
async def test_admin_profile_change_keeps_app_mcp_and_plan_ownership(
    client, database, admin_headers, actors
):
    phone = "135" + "56789012"
    code = await _new_otp(database, phone)
    login = await client.post("/api/auth/login", json={"phone": phone, "otp": code})
    assert login.status_code == 200
    patient_id = login.json()["user_id"]
    patient_headers = {"Authorization": "Bearer " + login.json()["access_token"]}
    before = await _user(database, phone)
    plan_response = await client.post(
        "/api/plans",
        headers=patient_headers,
        json={
            "drug_name": "Ownership test",
            "dosage": "1 tablet",
            "times": ["08:00"],
            "timezone": "UTC",
        },
    )
    assert plan_response.status_code == 201, plan_response.text
    plan_id = plan_response.json()["id"]
    binding_response = await client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": patient_id, "label": "Ownership test"},
    )
    assert binding_response.status_code == 201, binding_response.text
    binding = binding_response.json()
    async with database() as db:
        grant = Grant(
            patient_id=patient_id,
            caregiver_id=actors["caregiver"]["id"],
            status="active",
        )
        db.add(grant)
        await db.commit()
        grant_id = grant.id

    empty = await client.put(
        f"/api/admin/users/{patient_id}", headers=admin_headers, json={}
    )
    assert empty.status_code == 422
    updated = await client.put(
        f"/api/admin/users/{patient_id}",
        headers=admin_headers,
        json={"display_name": "  睡眠用户  ", "timezone": "Europe/London"},
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["display_name"] == "睡眠用户"
    me = await client.get("/api/auth/me", headers=patient_headers)
    assert me.status_code == 200
    assert me.json()["id"] == patient_id
    assert me.json()["display_name"] == "睡眠用户"
    assert me.json()["timezone"] == "Europe/London"
    tool = await client.post(
        "/api/mcp/tools/get_medication_plans",
        headers={"Authorization": "Bearer " + binding["token"]},
        json={},
    )
    assert tool.status_code == 200
    assert [p["id"] for p in tool.json()["plans"]] == [plan_id]
    async with database() as db:
        user = await db.get(User, patient_id)
        assert user.phone == before.phone
        assert user.password_hash == before.password_hash
        assert user.role == before.role
        assert user.active == before.active
        plan = await db.get(Plan, plan_id)
        assert plan.patient_id == patient_id
        assert plan.timezone == "UTC"
        assert (await db.get(Binding, binding["id"])).patient_id == patient_id
        assert (await db.get(Grant, grant_id)).patient_id == patient_id
        audit = await db.scalar(select(Audit).where(Audit.action == "account.updated"))
        assert audit.actor_id != patient_id
        assert audit.patient_id == audit.object_id == patient_id
        assert audit.detail == {"fields": ["display_name", "timezone"]}
        assert "睡眠用户" not in json.dumps(audit.detail, ensure_ascii=False)
        assert "Europe/London" not in json.dumps(audit.detail)


@pytest.mark.asyncio
async def test_cli_otp_for_new_phone_does_not_create_user(database):
    phone = "136" + "45678901"
    code = await _new_otp(database, phone)
    assert len(code) == 6
    assert await _user(database, phone) is None
    async with database() as db:
        audit = await db.scalar(select(Audit).where(Audit.action == "auth.otp_issued"))
        assert audit.patient_id is None
        assert audit.object_id is None
        assert audit.detail == {}


@pytest.mark.asyncio
@pytest.mark.parametrize("phone", [None, "", "123", "138123456789", "12812345678"])
async def test_cli_rejects_invalid_phone_without_creating_otp(database, phone):
    async with database() as db:
        with pytest.raises(ValueError, match="valid mainland China"):
            await issue_otp(db, phone)
        assert await db.scalar(select(func.count(OTP.id))) == 0


@pytest.mark.asyncio
async def test_parallel_first_otp_issue_and_replay_have_single_identity(
    client, database
):
    phone = "134" + "67890123"
    issued_codes = await asyncio.gather(
        _new_otp(database, phone), _new_otp(database, phone)
    )
    async with database() as db:
        challenges = (await db.scalars(select(OTP).where(OTP.phone == phone))).all()
        assert len(challenges) == 2
        current = [otp for otp in challenges if not otp.used]
        assert len(current) == 1
        code = next(
            code
            for code in issued_codes
            if digest(phone + ":" + code + ":" + settings.secret)
            == current[0].code_hash
        )
    results = await asyncio.gather(
        client.post("/api/auth/login", json={"phone": phone, "otp": code}),
        client.post("/api/auth/login", json={"phone": phone, "otp": code}),
    )
    assert sorted(response.status_code for response in results) == [200, 401]
    success = next(response for response in results if response.status_code == 200)
    user = await _user(database, phone)
    assert user.id == success.json()["user_id"]
    async with database() as db:
        assert (
            await db.scalar(select(func.count(User.id)).where(User.phone == phone)) == 1
        )


@pytest.mark.asyncio
async def test_admin_creation_and_app_first_login_race_preserve_single_account(
    client, database, admin_headers
):
    phone = "133" + "78901234"
    code = await _new_otp(database, phone)
    admin_created, login = await asyncio.gather(
        client.post(
            "/api/admin/users",
            headers=admin_headers,
            json={
                "phone": phone,
                "display_name": "Operator created",
                "password": "Test-operator-password-2026",
            },
        ),
        client.post("/api/auth/login", json={"phone": phone, "otp": code}),
    )
    assert admin_created.status_code in (201, 409), admin_created.text
    assert login.status_code == 200, login.text
    user = await _user(database, phone)
    assert user.id == login.json()["user_id"]
    if admin_created.status_code == 201:
        assert admin_created.json()["id"] == user.id
    async with database() as db:
        assert (
            await db.scalar(select(func.count(User.id)).where(User.phone == phone)) == 1
        )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "patch",
    [
        {},
        {"display_name": None, "timezone": None},
        {"display_name": "   "},
        {"timezone": ""},
        {"timezone": "Not/AZone"},
        {"role": "admin"},
        {"phone": "13812345678"},
        {"password": "Test-changed-password-2026"},
        {"active": True},
        {"id": "new-identity"},
    ],
)
async def test_patient_profile_rejects_empty_or_privileged_fields(
    client, actors, admin_headers, patch
):
    response = await client.put(
        f"/api/admin/users/{actors['patient']['id']}", headers=admin_headers, json=patch
    )
    assert response.status_code == 422, response.text


@pytest.mark.asyncio
async def test_profile_edit_requires_admin_and_patient_target(
    client, database, actors, admin_headers
):
    patient_id = actors["patient"]["id"]
    for headers, status in (({}, 401), (actors["patient"]["headers"], 403)):
        denied = await client.put(
            f"/api/admin/users/{patient_id}",
            headers=headers,
            json={"display_name": "Unauthorized rename"},
        )
        assert denied.status_code == status
    async with database() as db:
        admin_id = await db.scalar(select(User.id).where(User.role == "admin"))
    for target in (admin_id, actors["caregiver"]["id"], "missing-user"):
        denied = await client.put(
            f"/api/admin/users/{target}",
            headers=admin_headers,
            json={"display_name": "Unauthorized target"},
        )
        assert denied.status_code == 404


@pytest.mark.asyncio
async def test_sms_request_does_not_claim_delivery_or_create_account(client, database):
    phone = "132" + "89012345"
    response = await client.post("/api/auth/otp", json={"phone": phone})
    assert response.status_code == 503
    assert await _user(database, phone) is None
    async with database() as db:
        assert await db.scalar(select(func.count(OTP.id))) == 0
