from __future__ import annotations

import asyncio
import importlib.util
import json
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import inspect, select, text
from sqlalchemy.ext.asyncio import create_async_engine

from app.config import get_settings
from app.db import Base
from app.models import Dose, Grant, Notification, Plan, User
from app.worker import deliver_notifications, run_once

NOW = datetime(2026, 10, 12, 12, tzinfo=timezone.utc)


async def seed_backlog(database, actors, count=8, channel="inbox", limit=3):
    patient_id, caregiver_id = actors["patient"]["id"], actors["caregiver"]["id"]
    async with database() as db:
        patient = await db.get(User, patient_id)
        patient.settings = {
            **patient.settings,
            "quiet_start": "00:00",
            "quiet_end": "00:00",
            "daily_push_limit": limit,
        }
        db.add(Grant(patient_id=patient_id, caregiver_id=caregiver_id, status="active"))
        plan = Plan(
            patient_id=patient_id,
            drug_name="Worker test medication",
            dosage="1 unit",
            times=["12:00"],
            timezone="UTC",
            active=False,
        )
        db.add(plan)
        await db.flush()
        for index in range(count):
            yesterday = NOW - timedelta(days=1, minutes=index)
            dose = Dose(
                patient_id=patient_id,
                plan_id=plan.id,
                plan_version=1,
                drug_name=plan.drug_name,
                dosage=plan.dosage,
                timezone="UTC",
                scheduled_time=yesterday,
                status="confirmed",
                actual_time=yesterday,
                result="ontime",
                confirmed_by="user_tap",
            )
            db.add(dose)
            await db.flush()
            db.add(
                Notification(
                    patient_id=patient_id,
                    target_id=caregiver_id,
                    dose_id=dose.id,
                    created_at=yesterday,
                    event="dose_confirmed",
                    channel=channel,
                    status="queued",
                    next_attempt_at=NOW,
                    payload={
                        "dose_instance_id": dose.id,
                        "event": "dose_confirmed",
                        "state": "confirmed",
                    },
                )
            )
        await db.commit()
    return caregiver_id


async def read_notifications(database, caregiver_id):
    async with database() as db:
        return (
            await db.scalars(
                select(Notification).where(Notification.target_id == caregiver_id)
            )
        ).all()


@pytest.mark.asyncio
async def test_yesterday_backlog_respects_today_delivery_limit(database, actors):
    caregiver_id = await seed_backlog(database, actors)
    async with database() as db:
        await run_once(db, now=NOW)
        await db.commit()
    rows = await read_notifications(database, caregiver_id)
    delivered = [row for row in rows if row.status == "inbox_ready"]
    deferred = [row for row in rows if row.status == "queued"]
    assert len(delivered) == 3
    assert len(deferred) == 5
    assert all(
        row.created_at.date() == (NOW - timedelta(days=1)).date() for row in rows
    )
    assert all(row.delivered_at == NOW for row in delivered)
    assert all(row.delivered_at is None and row.attempts == 0 for row in deferred)
    tomorrow_start = (NOW + timedelta(days=1)).replace(hour=0)
    assert all(row.next_attempt_at == tomorrow_start for row in deferred)

    async with database() as db:
        await run_once(db, now=NOW + timedelta(minutes=1))
        await db.commit()
    rows = await read_notifications(database, caregiver_id)
    assert sum(row.status == "inbox_ready" for row in rows) == 3

    tomorrow = NOW + timedelta(days=1)
    async with database() as db:
        await run_once(db, now=tomorrow)
        await db.commit()
    rows = await read_notifications(database, caregiver_id)
    assert sum(row.status == "inbox_ready" for row in rows) == 6
    assert sum(row.delivered_at == tomorrow for row in rows) == 3


@pytest.mark.asyncio
async def test_webhook_records_delivery_time_only_after_success(
    database, actors, monkeypatch
):
    caregiver_id = await seed_backlog(database, actors, count=1, channel="webhook")
    state = {"requests": [], "status": 503}
    expected_token = "worker-test-webhook-token"

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["requests"].append((payload, self.headers.get("Idempotency-Key")))
            authorized = self.headers.get("Authorization") == f"Bearer {expected_token}"
            self.send_response(state["status"] if authorized else 401)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_):
            pass

    webhook = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=webhook.serve_forever, daemon=True)
    thread.start()
    settings = get_settings()
    monkeypatch.setattr(
        settings,
        "notification_webhook",
        f"http://127.0.0.1:{webhook.server_port}/notify",
    )
    monkeypatch.setattr(settings, "notification_webhook_token", expected_token)
    try:
        async with database() as db:
            await run_once(db, now=NOW)
            await db.commit()
        row = (await read_notifications(database, caregiver_id))[0]
        assert row.status == "retrying" and row.delivered_at is None
        assert row.attempts == 1
        state["status"] = 200
        successful_time = NOW + timedelta(seconds=61)
        async with database() as db:
            await run_once(db, now=successful_time)
            await db.commit()
        row = (await read_notifications(database, caregiver_id))[0]
        assert row.status == "delivered" and row.delivered_at == successful_time
        assert row.last_error is None and row.attempts == 2
        assert len(state["requests"]) == 2
        assert state["requests"][0][1] == state["requests"][1][1] == row.id
    finally:
        webhook.shutdown()
        webhook.server_close()
        thread.join(timeout=5)


@pytest.mark.asyncio
async def test_concurrent_workers_share_the_family_delivery_budget(
    database, actors, monkeypatch
):
    caregiver_id = await seed_backlog(database, actors, count=105, channel="webhook")
    first_request = threading.Event()
    release_delivery = threading.Event()
    deliveries = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            deliveries.append(self.headers.get("Idempotency-Key"))
            first_request.set()
            released = release_delivery.wait(timeout=10)
            self.send_response(200 if released else 503)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *_):
            pass

    webhook = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=webhook.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setattr(
        get_settings(),
        "notification_webhook",
        f"http://127.0.0.1:{webhook.server_port}/notify",
    )
    monkeypatch.setattr(
        get_settings(), "notification_webhook_token", "worker-test-webhook-token"
    )

    async def deliver_batch():
        async with database() as db:
            await deliver_notifications(db, now=NOW)
            await db.commit()

    worker = asyncio.create_task(deliver_batch())
    try:
        assert await asyncio.to_thread(first_request.wait, 5)
        # The first worker holds 100 outbox rows while awaiting the real HTTP response.
        # The second worker can claim the remaining rows but shares the same delivery budget.
        await asyncio.wait_for(deliver_batch(), timeout=5)
        release_delivery.set()
        await asyncio.wait_for(worker, timeout=10)
        rows = await read_notifications(database, caregiver_id)
        assert len(deliveries) == 3
        assert len(set(deliveries)) == 3
        assert sum(row.status == "delivered" for row in rows) == 3
    finally:
        release_delivery.set()
        await asyncio.wait_for(worker, timeout=10)
        webhook.shutdown()
        webhook.server_close()
        thread.join(timeout=5)


def migration_module(filename):
    path = Path(__file__).resolve().parents[1] / "migrations" / "versions" / filename
    spec = importlib.util.spec_from_file_location(filename.replace(".py", ""), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apply_migration(connection, migration, direction="upgrade"):
    with Operations.context(MigrationContext.configure(connection)):
        getattr(migration, direction)()


@pytest.mark.asyncio
async def test_frozen_initial_migration_and_delivery_upgrade_preserve_data(database):
    schema = "test_worker_migration_" + uuid4().hex
    url = database.kw["bind"].url
    administration = create_async_engine(url)
    async with administration.begin() as connection:
        await connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    migration_engine = create_async_engine(
        url, connect_args={"server_settings": {"search_path": schema}}
    )
    initial = migration_module("0001_initial.py")
    delivery = migration_module("0002_notification_delivery_time.py")
    mcp_connections = migration_module("0003_mcp_connections.py")
    try:
        async with migration_engine.begin() as connection:
            await connection.run_sync(apply_migration, initial)
            initial_columns = await connection.run_sync(
                lambda c: {
                    item["name"]
                    for item in inspect(c).get_columns("notification_outbox")
                }
            )
            assert "delivered_at" not in initial_columns
            patient_id = str(uuid4())
            binding_id = str(uuid4())
            await connection.execute(
                text(
                    "INSERT INTO users (id,created_at,username,display_name,password_hash,role,timezone,active,settings) "
                    "VALUES (:id,:created_at,'migration-patient','Migration patient','test-only-hash','patient','UTC',true,'{}')"
                ),
                {"id": patient_id, "created_at": NOW},
            )
            await connection.execute(
                text(
                    "INSERT INTO mcp_bindings (id,created_at,patient_id,label,token_hash,active) "
                    "VALUES (:id,:created_at,:patient_id,'Existing binding',:token_hash,true)"
                ),
                {"id": binding_id, "created_at": NOW, "patient_id": patient_id,
                 "token_hash": "a" * 64},
            )
            await connection.run_sync(apply_migration, delivery)
            await connection.run_sync(apply_migration, mcp_connections)
            upgraded_columns = await connection.run_sync(
                lambda c: {
                    item["name"]
                    for item in inspect(c).get_columns("notification_outbox")
                }
            )
            assert upgraded_columns == set(
                Base.metadata.tables["notification_outbox"].columns.keys()
            )
            assert await connection.scalar(text("SELECT count(*) FROM users")) == 1
            assert await connection.scalar(text("SELECT count(*) FROM mcp_bindings")) == 1
            assert await connection.scalar(text("SELECT count(*) FROM mcp_connections")) == 0
            tables = await connection.run_sync(
                lambda c: set(inspect(c).get_table_names())
            )
            assert tables == set(Base.metadata.tables)
            for table_name, table in Base.metadata.tables.items():
                columns = await connection.run_sync(
                    lambda c, name=table_name: {
                        item["name"] for item in inspect(c).get_columns(name)
                    }
                )
                assert columns == set(table.columns.keys())
            differences = await connection.run_sync(
                lambda c: compare_metadata(
                    MigrationContext.configure(c, opts={"compare_type": True}),
                    Base.metadata,
                )
            )
            assert not differences
            await connection.run_sync(apply_migration, mcp_connections, "downgrade")
            await connection.run_sync(apply_migration, delivery, "downgrade")
            assert await connection.scalar(text("SELECT count(*) FROM users")) == 1
            assert await connection.scalar(text("SELECT count(*) FROM mcp_bindings")) == 1
    finally:
        await migration_engine.dispose()
        async with administration.begin() as connection:
            await connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        await administration.dispose()
