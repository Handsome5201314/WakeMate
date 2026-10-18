"""Real DB, HTTP API, WebSocket, and MCP SDK tests of persisted connections."""

from __future__ import annotations

import asyncio
import logging
import socket
import time
from contextlib import asynccontextmanager

import anyio
import mcp.types as types
import pytest
import pytest_asyncio
import uvicorn
import websockets
from mcp import ClientSession
from mcp.shared.message import SessionMessage
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app.main import app
from app.mcp_connections import endpoint_hash, seal_config
from app.mcp_manager import (
    ConnectionSnapshot,
    healthcheck,
    record_state,
    run_manager,
)
from app.models import Binding, MCPConnection, User
from app.security import digest


@pytest_asyncio.fixture
async def manager_http(client):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    address = f"http://127.0.0.1:{listener.getsockname()[1]}"
    server = uvicorn.Server(
        uvicorn.Config(
            app, lifespan="off", access_log=False, log_level="critical", ws="none"
        )
    )
    task = asyncio.create_task(server.serve(sockets=[listener]))

    async def started():
        while not server.started:
            if task.done():
                await task
                raise RuntimeError("Test HTTP server stopped before readiness")
            await asyncio.sleep(0.01)

    try:
        await asyncio.wait_for(started(), 5)
        yield address
    finally:
        server.should_exit = True
        await asyncio.wait_for(task, 5)
        listener.close()


@asynccontextmanager
async def websocket_client(websocket):
    writer, inbound = anyio.create_memory_object_stream(16)
    outbound, reader = anyio.create_memory_object_stream(16)
    async with anyio.create_task_group() as group:

        async def receive():
            async with writer:
                async for frame in websocket:
                    await writer.send(
                        SessionMessage(types.JSONRPCMessage.model_validate_json(frame))
                    )

        async def send():
            async with reader:
                async for message in reader:
                    await websocket.send(
                        message.message.model_dump_json(
                            by_alias=True, exclude_none=True
                        )
                    )

        group.start_soon(receive)
        group.start_soon(send)
        async with inbound, outbound, ClientSession(inbound, outbound) as session:
            yield session
        group.cancel_scope.cancel()


async def wait_state(database, binding_id, wanted, *, timeout=5):
    async def poll():
        while True:
            async with database() as db:
                row = await db.get(MCPConnection, binding_id)
                if row is not None and row.state == wanted:
                    return row
            await asyncio.sleep(0.02)

    return await asyncio.wait_for(poll(), timeout)


async def wait_healthy(path):
    async def poll():
        while not healthcheck(path):
            await asyncio.sleep(0.02)

    await asyncio.wait_for(poll(), 5)


async def create_binding(client, admin_headers, patient_id):
    response = await client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": patient_id, "label": "Loopback MCP integration"},
    )
    assert response.status_code == 201, response.text
    return response.json()


async def store_test_connection(database, binding, endpoint, *, token=None):
    token = token or binding["token"]
    async with database() as db:
        row = await db.get(MCPConnection, binding["id"])
        if row is None:
            row = MCPConnection(binding_id=binding["id"], generation=1)
            db.add(row)
        else:
            row.generation += 1
        row.encrypted_config = seal_config(endpoint, token, allow_loopback=True)
        row.endpoint_hash = endpoint_hash(endpoint, allow_loopback=True)
        row.state = "queued"
        row.heartbeat = None
        row.connected_at = None
        row.last_error = None
        owner = await db.get(Binding, binding["id"])
        owner.token_hash = digest(token)
        await db.commit()
        return ConnectionSnapshot(row.binding_id, row.generation, row.encrypted_config)


async def stop_manager(task, stop):
    stop.set()
    await asyncio.wait_for(task, 5)


async def test_persisted_mcp_connect_update_restart_and_revoke(
    client, database, actors, admin_headers, manager_http, tmp_path, caplog
):
    caplog.set_level(logging.INFO)
    plan = await client.post(
        "/api/plans",
        headers=actors["patient"]["headers"],
        json={
            "drug_name": "Integration medicine",
            "dosage": "1 tablet",
            "times": ["08:00"],
        },
    )
    assert plan.status_code == 201, plan.text
    binding = await create_binding(client, admin_headers, actors["patient"]["id"])
    completed = asyncio.Queue()
    closed = asyncio.Queue()
    failures = []
    count = 0

    async def endpoint(websocket):
        nonlocal count
        count += 1
        identifier = count
        try:
            async with websocket_client(websocket) as session:
                initialized = await session.initialize()
                assert initialized.serverInfo.name == "wakemate-readonly"
                listed = await session.list_tools()
                assert {tool.name for tool in listed.tools} == {
                    "get_today_doses",
                    "get_dose_status",
                    "get_recent_medication_history",
                    "get_medication_plans",
                    "get_device_status",
                }
                result = await session.call_tool("get_medication_plans", {})
                assert not result.isError
                assert {item["id"] for item in result.structuredContent["plans"]} == {
                    plan.json()["id"]
                }
                await completed.put(identifier)
                await websocket.wait_closed()
        except Exception as exc:
            failures.append(type(exc).__name__)
            await completed.put(exc)
        finally:
            await closed.put(identifier)

    status_file = tmp_path / "manager.json"
    async with websockets.serve(endpoint, "127.0.0.1", 0) as service:
        port = service.sockets[0].getsockname()[1]
        address = f"ws://127.0.0.1:{port}/mcp?token=private-endpoint-one"
        original = await store_test_connection(database, binding, address)
        stop = asyncio.Event()
        manager = asyncio.create_task(
            run_manager(
                database,
                stop,
                api_url=manager_http,
                status_file=status_file,
                poll_interval=0.05,
                allow_loopback=True,
            )
        )
        try:
            assert await asyncio.wait_for(completed.get(), 10) == 1
            connected = await wait_state(database, binding["id"], "connected")
            assert connected.heartbeat is not None
            assert connected.connected_at is not None
            assert healthcheck(status_file)
            replacement = await store_test_connection(
                database,
                binding,
                address.replace("one", "two"),
                token="private-api-token-two",
            )
            # Callback from an old task must not corrupt a queued new generation.
            await record_state(database, original, "connected")
            assert await asyncio.wait_for(completed.get(), 10) == 2
            assert await asyncio.wait_for(closed.get(), 5) == 1
            connected = await wait_state(database, binding["id"], "connected")
            assert connected.generation == replacement.generation
            # A manager restart reads only the existing encrypted database configuration.
            await stop_manager(manager, stop)
            assert await asyncio.wait_for(closed.get(), 5) == 2
            assert not healthcheck(status_file)
            assert (
                await wait_state(database, binding["id"], "stopped")
            ).encrypted_config == (replacement.encrypted_config)
            stop = asyncio.Event()
            manager = asyncio.create_task(
                run_manager(
                    database,
                    stop,
                    api_url=manager_http,
                    status_file=status_file,
                    poll_interval=0.05,
                    allow_loopback=True,
                )
            )
            assert await asyncio.wait_for(completed.get(), 10) == 3
            revoked = await client.post(
                f"/api/admin/mcp-bindings/{binding['id']}/revoke", headers=admin_headers
            )
            assert revoked.status_code == 200, revoked.text
            assert await asyncio.wait_for(closed.get(), 5) == 3
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(completed.get(), 0.2)
            async with database() as db:
                assert await db.get(MCPConnection, binding["id"]) is None
                assert not (await db.get(Binding, binding["id"])).active
            assert healthcheck(status_file)
        finally:
            await stop_manager(manager, stop)
    assert not failures
    assert count == 3
    private = (
        binding["token"],
        "private-api-token-two",
        "private-endpoint-one",
        "private-endpoint-two",
    )
    for secret in private:
        assert secret not in caplog.text
        for status in tmp_path.rglob("*.json"):
            assert secret not in status.read_text()


async def test_empty_manager_is_healthy_and_singleton(database, tmp_path):
    path = tmp_path / "manager.json"
    stop = asyncio.Event()
    first = asyncio.create_task(
        run_manager(database, stop, status_file=path, poll_interval=0.05)
    )
    try:
        await wait_healthy(path)
        with pytest.raises(RuntimeError, match="database lock"):
            await run_manager(database, status_file=tmp_path / "second.json")
        assert healthcheck(path)
    finally:
        await stop_manager(first, stop)
    assert not healthcheck(path)
    resumed_stop = asyncio.Event()
    resumed = asyncio.create_task(
        run_manager(database, resumed_stop, status_file=path, poll_interval=0.05)
    )
    try:
        await wait_healthy(path)
    finally:
        await stop_manager(resumed, resumed_stop)


async def test_database_lock_connection_loss_stops_manager(database, tmp_path):
    path = tmp_path / "manager.json"
    manager = asyncio.create_task(
        run_manager(database, status_file=path, poll_interval=0.05)
    )
    try:
        await wait_healthy(path)
        async with database() as db:
            owner = await db.scalar(
                text(
                    "SELECT pid FROM pg_locks WHERE locktype = 'advisory' "
                    "AND ((classid::bigint << 32) | objid::bigint) = "
                    "hashtextextended('wakemate:mcp-manager:' || current_database() "
                    "|| ':' || current_schema(), 0) AND objsubid = 1 AND granted"
                )
            )
            assert owner is not None
            # Only the manager session owning this test schema's lock is terminated.
            assert await db.scalar(
                text("SELECT pg_terminate_backend(:pid)"), {"pid": owner}
            )
            await db.commit()
        with pytest.raises((SQLAlchemyError, RuntimeError)):
            await asyncio.wait_for(manager, 5)
        assert not healthcheck(path)
    finally:
        if not manager.done():
            manager.cancel()
            await asyncio.gather(manager, return_exceptions=True)


async def test_corrupt_configuration_is_observable_without_secrets(
    client, database, actors, admin_headers, tmp_path
):
    binding = await create_binding(client, admin_headers, actors["patient"]["id"])
    async with database() as db:
        db.add(
            MCPConnection(
                binding_id=binding["id"],
                generation=1,
                endpoint_hash=digest("corrupt"),
                encrypted_config="invalid-private-ciphertext",
                state="queued",
            )
        )
        await db.commit()
    stop = asyncio.Event()
    path = tmp_path / "manager.json"
    manager = asyncio.create_task(
        run_manager(database, stop, status_file=path, poll_interval=0.05)
    )
    try:
        row = await wait_state(database, binding["id"], "error")
        assert row.last_error == "config_invalid"
        assert row.connected_at is None
        assert healthcheck(path)
        listed = await client.get("/api/admin/mcp-bindings", headers=admin_headers)
        assert listed.status_code == 200
        assert "invalid-private-ciphertext" not in listed.text
        assert binding["token"] not in listed.text
    finally:
        await stop_manager(manager, stop)


async def test_connection_failure_is_retrying_and_patient_deactivation_stops_it(
    client, database, actors, admin_headers, tmp_path
):
    binding = await create_binding(client, admin_headers, actors["patient"]["id"])
    # Binding the socket reserves the port without listening: connection is refused.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    endpoint = (
        f"ws://127.0.0.1:{listener.getsockname()[1]}/mcp?token=private-retry-token"
    )
    await store_test_connection(database, binding, endpoint)
    stop = asyncio.Event()
    manager = asyncio.create_task(
        run_manager(
            database,
            stop,
            status_file=tmp_path / "manager.json",
            poll_interval=0.05,
            retry_initial=1,
            retry_max=1,
            allow_loopback=True,
        )
    )
    try:
        row = await wait_state(database, binding["id"], "retrying")
        assert row.last_error == "ConnectionRefusedError"
        assert row.heartbeat is not None
        assert row.connected_at is None
        async with database() as db:
            patient = await db.get(User, actors["patient"]["id"])
            patient.active = False
            await db.commit()
        await wait_state(database, binding["id"], "stopped")
    finally:
        await stop_manager(manager, stop)
        listener.close()


async def test_same_generation_after_recreation_rejects_old_callback(
    client, database, actors, admin_headers
):
    binding = await create_binding(client, admin_headers, actors["patient"]["id"])
    endpoint = "ws://127.0.0.1:12345/mcp?token=aba-test"
    original = await store_test_connection(database, binding, endpoint)
    async with database() as db:
        await db.delete(await db.get(MCPConnection, binding["id"]))
        await db.commit()
    replacement = await store_test_connection(database, binding, endpoint)
    assert replacement.generation == original.generation == 1
    assert replacement.encrypted_config != original.encrypted_config
    await record_state(database, original, "connected")
    async with database() as db:
        row = await db.get(MCPConnection, binding["id"])
        assert row.state == "queued"
        assert row.heartbeat is None
        assert row.connected_at is None
    await record_state(database, replacement, "connected")
    await wait_state(database, binding["id"], "connected")


async def test_retry_heartbeats_preserve_backoff_and_error(
    client, database, actors, admin_headers, tmp_path
):
    binding = await create_binding(client, admin_headers, actors["patient"]["id"])
    attempts = asyncio.Queue()
    times = []

    async def endpoint(websocket):
        times.append(time.monotonic())
        await attempts.put(len(times))
        await websocket.close()

    async with websockets.serve(endpoint, "127.0.0.1", 0) as service:
        port = service.sockets[0].getsockname()[1]
        await store_test_connection(
            database, binding, f"ws://127.0.0.1:{port}/mcp?token=retry-heartbeat-test"
        )
        stop = asyncio.Event()
        manager = asyncio.create_task(
            run_manager(
                database,
                stop,
                status_file=tmp_path / "manager.json",
                poll_interval=0.02,
                retry_initial=0.4,
                retry_max=0.4,
                retry_heartbeat=0.05,
                allow_loopback=True,
            )
        )
        try:
            assert await asyncio.wait_for(attempts.get(), 5) == 1
            first = await wait_state(database, binding["id"], "retrying")
            assert first.last_error == "transport_closed"

            async def heartbeat_advanced():
                while True:
                    async with database() as db:
                        row = await db.get(MCPConnection, binding["id"])
                        if row.state == "retrying" and row.heartbeat > first.heartbeat:
                            return row
                    await asyncio.sleep(0.01)

            updated = await asyncio.wait_for(heartbeat_advanced(), 5)
            assert updated.last_error == first.last_error
            assert updated.generation == first.generation
            assert len(times) == 1
            assert await asyncio.wait_for(attempts.get(), 5) == 2
            assert times[1] - times[0] >= 0.4
        finally:
            await stop_manager(manager, stop)
