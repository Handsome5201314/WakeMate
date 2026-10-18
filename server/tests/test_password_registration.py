"""Verify account/password App registration against isolated PostgreSQL schemas."""

import asyncio
import json

import httpx
import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.main import app
from app.models import Audit, LoginAttempt, User
from app.security import digest, verify_password


PASSWORD = "Registration-password-2026"


def _account(username="patient_one", **values):
    return {"username": username, "password": PASSWORD, **values}


def _headers(response):
    return {"Authorization": "Bearer " + response.json()["access_token"]}


def _source_client(source):
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(
            app=app, client=(source, 43002), raise_app_exceptions=False
        ),
        base_url="http://testserver",
    )


async def test_password_register_login_me_and_admin_share_one_patient(
    client, database, admin_headers
):
    registered = await client.post(
        "/api/auth/register",
        json=_account("  App_User_01  ", display_name="  醒伴用户  ", timezone="UTC"),
    )
    assert registered.status_code == 201, registered.text
    identity = registered.json()
    assert set(identity) == {
        "access_token", "token_type", "user_id", "role", "expires_in"
    }
    assert identity["role"] == "patient"
    assert identity["token_type"] == "bearer"
    assert identity["expires_in"] > 0
    me = await client.get("/api/auth/me", headers=_headers(registered))
    assert me.status_code == 200
    assert me.json()["id"] == identity["user_id"]
    assert me.json()["username"] == "App_User_01"
    assert me.json()["display_name"] == "醒伴用户"
    assert me.json()["timezone"] == "UTC"
    assert me.json()["phone_masked"] is None
    assert "password" not in me.json() and "password_hash" not in me.json()
    assert "phone" not in me.json()
    login = await client.post(
        "/api/auth/password", json=_account("App_User_01")
    )
    assert login.status_code == 200, login.text
    assert login.json()["user_id"] == identity["user_id"]
    listed = await client.get("/api/admin/patients", headers=admin_headers)
    assert listed.status_code == 200
    assert listed.json() == [me.json()]
    async with database() as db:
        user = await db.get(User, identity["user_id"])
        assert user.phone is None
        assert verify_password(PASSWORD, user.password_hash)
        assert user.password_hash != PASSWORD
        audit = await db.scalar(select(Audit).where(Audit.action == "account.created"))
        assert audit.actor_id == audit.patient_id == audit.object_id == user.id
        assert audit.detail == {"source": "app_password"}
        assert PASSWORD not in json.dumps(audit.detail)
    status = await client.get("/api/admin/status", headers=admin_headers)
    assert status.json()["auth_mode"] == "password_registration_and_operator_otp"


async def test_registration_defaults_and_case_sensitive_login(client):
    upper = await client.post("/api/auth/register", json=_account("Case_User"))
    assert upper.status_code == 201
    lower = await client.post(
        "/api/auth/register", json=_account("case_user", password=PASSWORD + "_lower")
    )
    assert lower.status_code == 201
    assert upper.json()["user_id"] != lower.json()["user_id"]
    me = await client.get("/api/auth/me", headers=_headers(upper))
    assert me.json()["display_name"] == "Case_User"
    assert me.json()["timezone"] == "Asia/Shanghai"
    wrong_case_password = await client.post(
        "/api/auth/password", json=_account("case_user")
    )
    assert wrong_case_password.status_code == 401
    login = await client.post("/api/auth/password", json=_account("Case_User"))
    assert login.status_code == 200
    assert login.json()["user_id"] == upper.json()["user_id"]


async def test_registered_patients_have_isolated_data_and_cannot_administer_accounts(
    client, admin_headers
):
    first = await client.post("/api/auth/register", json=_account("Patient_A"))
    second = await client.post("/api/auth/register", json=_account("Patient_B"))
    assert first.status_code == second.status_code == 201
    created = await client.post(
        "/api/plans",
        headers=_headers(first),
        json={"drug_name": "Isolation medicine", "dosage": "1 tablet", "times": ["08:00"]},
    )
    assert created.status_code == 201
    plan_id = created.json()["id"]
    first_plans = await client.get("/api/plans", headers=_headers(first))
    second_plans = await client.get("/api/plans", headers=_headers(second))
    assert [p["id"] for p in first_plans.json()] == [plan_id]
    assert second_plans.json() == []
    forbidden = await client.put(
        f"/api/plans/{plan_id}",
        headers=_headers(second),
        json={"drug_name": "Forbidden change", "dosage": "2 tablets", "times": ["09:00"]},
    )
    assert forbidden.status_code == 404
    assert (await client.get("/api/admin/patients", headers=_headers(first))).status_code == 403
    binding = await client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": first.json()["user_id"], "label": "Account registration"},
    )
    assert binding.status_code == 201
    tool = await client.post(
        "/api/mcp/tools/get_medication_plans",
        headers={"Authorization": "Bearer " + binding.json()["token"]},
        json={},
    )
    assert tool.status_code == 200
    assert [p["id"] for p in tool.json()["plans"]] == [plan_id]


async def test_duplicate_registration_never_overwrites_or_reactivates_account(
    client, database
):
    registered = await client.post("/api/auth/register", json=_account("existing_user"))
    assert registered.status_code == 201
    user_id = registered.json()["user_id"]
    async with database() as db:
        user = await db.get(User, user_id)
        old_hash = user.password_hash
        user.active = False
        await db.commit()
    duplicate = await client.post(
        "/api/auth/register",
        json=_account("existing_user", password=PASSWORD + "changed", display_name="changed"),
    )
    assert duplicate.status_code == 409
    assert (await client.post("/api/auth/password", json=_account("existing_user"))).status_code == 401
    assert (await client.get("/api/auth/me", headers=_headers(registered))).status_code == 401
    async with database() as db:
        user = await db.get(User, user_id)
        assert not user.active
        assert user.password_hash == old_hash
        assert user.display_name == "existing_user"
        assert await db.scalar(select(func.count(User.id)).where(User.username == "existing_user")) == 1
    reserved = await client.post("/api/auth/register", json=_account("admin"))
    assert reserved.status_code == 409


async def test_concurrent_registration_creates_one_patient_and_one_audit(
    client, database
):
    responses = await asyncio.gather(*(
        client.post("/api/auth/register", json=_account("concurrent_user"))
        for _ in range(8)
    ))
    assert [r.status_code for r in responses].count(201) == 1
    assert [r.status_code for r in responses].count(409) == 7
    async with database() as db:
        users = (await db.scalars(select(User).where(User.username == "concurrent_user"))).all()
        assert len(users) == 1
        created = (await db.scalars(select(Audit).where(Audit.action == "account.created"))).all()
        assert len(created) == 1
        assert created[0].object_id == users[0].id


@pytest.mark.parametrize("values", [
    {"username": "ab"},
    {"username": "a" * 33},
    {"username": "patient-one"},
    {"username": "中文账号"},
    {"username": "patient name"},
    {"password": "short_pass"},
    {"password": "p" * 129},
    {"display_name": "   "},
    {"timezone": "not/a/timezone"},
    {"role": "admin"},
    {"phone": "13812345678"},
    {"active": True},
])
async def test_invalid_registration_cannot_create_or_echo_password(client, database, values):
    body = _account(**values)
    response = await client.post("/api/auth/register", json=body)
    assert response.status_code == 422, response.text
    assert body["password"] not in response.text
    async with database() as db:
        assert await db.scalar(select(func.count(User.id)).where(User.role == "patient")) == 0


@pytest.mark.parametrize("length", [12, 128])
async def test_password_boundaries_are_supported_and_not_trimmed(client, length):
    password = " " + "p" * (length - 2) + " "
    registered = await client.post(
        "/api/auth/register", json=_account("boundary_user", password=password)
    )
    assert registered.status_code == 201
    trimmed = await client.post(
        "/api/auth/password", json=_account("boundary_user", password=password.strip())
    )
    assert trimmed.status_code == 401
    exact = await client.post(
        "/api/auth/password", json=_account("boundary_user", password=password)
    )
    assert exact.status_code == 200


async def test_registration_and_login_share_source_ip_limit(client, database):
    async with _source_client("198.51.100.71") as source:
        for number in range(15):
            invalid = await source.post(
                "/api/auth/password", json=_account(f"absent_{number}")
            )
            assert invalid.status_code == 401
        for number in range(15):
            registered = await source.post(
                "/api/auth/register", json=_account(f"limited_{number}")
            )
            assert registered.status_code == 201
        blocked = await source.post("/api/auth/register", json=_account("blocked_by_ip"))
        assert blocked.status_code == 429
    async with database() as db:
        assert await db.scalar(select(User).where(User.username == "blocked_by_ip")) is None
        assert (await db.get(LoginAttempt, digest("ip:198.51.100.71"))).count == 30


async def test_username_limit_is_shared_with_password_login(client, database):
    async with _source_client("198.51.100.72") as source:
        first = await source.post("/api/auth/register", json=_account("limited_user"))
        assert first.status_code == 201
        for _ in range(8):
            assert (await source.post("/api/auth/register", json=_account("limited_user"))).status_code == 409
        assert (await source.post("/api/auth/password", json=_account("limited_user"))).status_code == 200
        assert (await source.post("/api/auth/register", json=_account("limited_user"))).status_code == 429
        assert (await source.post("/api/auth/password", json=_account("limited_user"))).status_code == 429
    async with database() as db:
        assert (await db.get(LoginAttempt, digest("limited_user"))).count == 10


async def test_registration_commit_failure_returns_error_and_rolls_back_patient(
    client, database, monkeypatch, caplog
):
    original_commit = AsyncSession.commit

    async def fail_account_commit(session):
        if any(
            isinstance(row, Audit) and row.detail == {"source": "app_password"}
            for row in session.new
        ):
            raise RuntimeError("Simulated registration commit failure")
        await original_commit(session)

    monkeypatch.setattr(AsyncSession, "commit", fail_account_commit)
    response = await client.post("/api/auth/register", json=_account("transaction_user"))
    assert response.status_code == 500
    assert "access_token" not in response.json()
    assert PASSWORD not in response.text
    assert PASSWORD not in caplog.text
    async with database() as db:
        assert await db.scalar(select(User).where(User.username == "transaction_user")) is None
        assert await db.scalar(select(func.count(Audit.id)).where(Audit.action == "account.created")) == 0
