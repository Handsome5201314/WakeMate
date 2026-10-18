from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator

import httpx
import pytest_asyncio
from fastapi import Request
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine


TEST_DATABASE_URL = os.environ.get("TEST_DATABASE_URL") or os.environ.get(
    "WAKEMATE_DATABASE_URL"
)
if not TEST_DATABASE_URL:
    raise RuntimeError(
        "Set TEST_DATABASE_URL to a PostgreSQL asyncpg URL before running tests."
    )
if not TEST_DATABASE_URL.startswith("postgresql+asyncpg://"):
    raise RuntimeError("Business tests require PostgreSQL with the asyncpg driver.")

os.environ.setdefault("WAKEMATE_DATABASE_URL", TEST_DATABASE_URL)
os.environ.setdefault("WAKEMATE_SECRET", "test-only-signing-key-never-use-for-deployment")
os.environ.setdefault("WAKEMATE_ADMIN_PASSWORD", "Test-admin-password-2026")

from app.db import Base, get_db  # noqa: E402
from app.main import app  # noqa: E402
from app.services import ensure_admin  # noqa: E402


@pytest_asyncio.fixture
async def database() -> AsyncIterator[async_sessionmaker]:
    schema = "test_wakemate_" + uuid.uuid4().hex
    administration_engine = create_async_engine(TEST_DATABASE_URL)
    async with administration_engine.begin() as connection:
        await connection.execute(text(f'CREATE SCHEMA "{schema}"'))

    engine = create_async_engine(
        TEST_DATABASE_URL,
        connect_args={"server_settings": {"search_path": schema}},
    )
    sessions = async_sessionmaker(engine, expire_on_commit=False)
    try:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with sessions() as session:
            await ensure_admin(session)
            await session.commit()
        yield sessions
    finally:
        await engine.dispose()
        async with administration_engine.begin() as connection:
            await connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        await administration_engine.dispose()


@pytest_asyncio.fixture
async def client(database: async_sessionmaker) -> AsyncIterator[httpx.AsyncClient]:
    async def test_database(request: Request):
        async with database() as session:
            request.state.db = session
            try:
                yield session
            except Exception:
                await session.rollback()
                raise

    previous_override = app.dependency_overrides.get(get_db)
    app.dependency_overrides[get_db] = test_database
    try:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
            base_url="http://testserver",
        ) as http_client:
            yield http_client
    finally:
        if previous_override is None:
            app.dependency_overrides.pop(get_db, None)
        else:
            app.dependency_overrides[get_db] = previous_override


@pytest_asyncio.fixture
async def admin_headers(client: httpx.AsyncClient) -> dict[str, str]:
    response = await client.post(
        "/api/auth/password",
        json={"username": "admin", "password": os.environ["WAKEMATE_ADMIN_PASSWORD"]},
    )
    assert response.status_code == 200, response.text
    return {"Authorization": "Bearer " + response.json()["access_token"]}


@pytest_asyncio.fixture
async def actors(client: httpx.AsyncClient, admin_headers: dict[str, str]):
    users = {}
    for name, role in (
        ("patient", "patient"),
        ("other_patient", "patient"),
        ("caregiver", "caregiver"),
    ):
        phone = "199" + f"{uuid.uuid4().int % 100_000_000:08d}"
        password = "Test-account-password-2026"
        response = await client.post(
            "/api/admin/users",
            headers=admin_headers,
            json={
                "phone": phone,
                "display_name": "Test " + name,
                "role": role,
                "password": password,
                "timezone": "UTC",
            },
        )
        assert response.status_code in (200, 201), response.text
        identity = response.json()
        login = await client.post(
            "/api/auth/password", json={"username": phone, "password": password}
        )
        assert login.status_code == 200, login.text
        users[name] = {
            "id": identity["id"],
            "phone": phone,
            "headers": {"Authorization": "Bearer " + login.json()["access_token"]},
        }
    return users
