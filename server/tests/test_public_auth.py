"""Exercise public login limits through real PostgreSQL transactions."""

from __future__ import annotations

import asyncio
import uuid
from datetime import timedelta

import httpx
from sqlalchemy import select

from app.main import app
from app.models import LoginAttempt, utcnow
from app.security import digest


def _source_client(source):
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(
            app=app, client=(source, 43001), raise_app_exceptions=False
        ),
        base_url="http://testserver",
    )


async def _password_attempt(http_client, headers=None):
    return await http_client.post(
        "/api/auth/password",
        headers=headers,
        json={
            "username": "absent-" + uuid.uuid4().hex,
            "password": "Invalid-test-password",
        },
    )


async def test_same_ip_random_usernames_are_limited_at_request_31(client, database):
    source = "198.51.100.10"
    async with _source_client(source) as http_client:
        for _ in range(30):
            response = await _password_attempt(http_client)
            assert response.status_code == 401
        blocked = await _password_attempt(http_client)
        assert blocked.status_code == 429
    async with database() as session:
        row = await session.get(LoginAttempt, digest("ip:" + source))
        assert row.count == 30
        keys = (await session.scalars(select(LoginAttempt.key))).all()
        assert all(len(key) == 64 and source not in key for key in keys)


async def test_different_source_ips_have_independent_login_budgets(client):
    async with _source_client("198.51.100.11") as exhausted:
        for _ in range(30):
            assert (await _password_attempt(exhausted)).status_code == 401
        assert (await _password_attempt(exhausted)).status_code == 429
    async with _source_client("198.51.100.12") as independent:
        assert (await _password_attempt(independent)).status_code == 401


async def test_untrusted_forwarded_headers_cannot_change_login_source(client):
    async with _source_client("198.51.100.13") as http_client:
        for sequence in range(30):
            spoofed = {
                "X-Forwarded-For": f"192.0.2.{sequence + 1}",
                "X-Real-IP": f"192.0.2.{sequence + 1}",
            }
            assert (await _password_attempt(http_client, spoofed)).status_code == 401
        blocked = await _password_attempt(
            http_client, {"X-Forwarded-For": "203.0.113.99"}
        )
        assert blocked.status_code == 429


async def test_password_and_otp_share_the_source_ip_budget(client):
    async with _source_client("198.51.100.14") as http_client:
        for _ in range(15):
            assert (await _password_attempt(http_client)).status_code == 401
        for sequence in range(15):
            response = await http_client.post(
                "/api/auth/login", json={"phone": f"199{sequence:08d}", "otp": "000000"}
            )
            assert response.status_code == 401
        otp_blocked = await http_client.post(
            "/api/auth/login", json={"phone": "19999999999", "otp": "000000"}
        )
        assert otp_blocked.status_code == 429
        assert (await _password_attempt(http_client)).status_code == 429


async def test_source_ip_window_resets_after_expiry(client, database):
    source = "198.51.100.15"
    async with _source_client(source) as http_client:
        for _ in range(30):
            assert (await _password_attempt(http_client)).status_code == 401
        assert (await _password_attempt(http_client)).status_code == 429
        async with database() as session:
            row = await session.get(LoginAttempt, digest("ip:" + source))
            row.reset_at = utcnow() - timedelta(seconds=1)
            await session.commit()
        assert (await _password_attempt(http_client)).status_code == 401
    async with database() as session:
        row = await session.get(LoginAttempt, digest("ip:" + source))
        assert row.count == 1
        assert row.reset_at > utcnow()


async def test_concurrent_first_requests_cannot_exceed_the_source_ip_budget(
    client, database
):
    source = "198.51.100.16"
    async with _source_client(source) as http_client:
        responses = await asyncio.gather(
            *(_password_attempt(http_client) for _ in range(35))
        )
    statuses = [response.status_code for response in responses]
    assert statuses.count(401) == 30
    assert statuses.count(429) == 5
    async with database() as session:
        row = await session.get(LoginAttempt, digest("ip:" + source))
        assert row.count == 30
