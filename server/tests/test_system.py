"""Verify the real HTTP API and official MCP client against isolated PostgreSQL."""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import socket
import sys
import tempfile
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
import pytest_asyncio
import uvicorn
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from app.main import app


@pytest_asyncio.fixture
async def real_http(client):
    # The existing client fixture installs the isolated database dependency.
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

    async def wait_started():
        while not server.started:
            if task.done():
                await task
                raise RuntimeError("Temporary HTTP server stopped before readiness")
            await asyncio.sleep(0.025)

    try:
        await asyncio.wait_for(wait_started(), timeout=5)
        async with httpx.AsyncClient(
            base_url=address, timeout=5, trust_env=False
        ) as http_client:
            health = await http_client.get("/health")
            assert health.status_code == 200
            yield http_client, address
    finally:
        server.should_exit = True
        try:
            await asyncio.wait_for(task, timeout=5)
        except TimeoutError:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        listener.close()


def _tool_data(result):
    assert not result.isError
    payload = json.loads(result.content[0].text)
    assert result.structuredContent == payload
    return payload


async def test_http_confirmation_is_visible_through_mcp_and_revocation_is_immediate(
    real_http,
):
    http_client, api_url = real_http
    login = await http_client.post(
        "/api/auth/password",
        json={"username": "admin", "password": os.environ["WAKEMATE_ADMIN_PASSWORD"]},
    )
    assert login.status_code == 200
    admin_headers = {"Authorization": "Bearer " + login.json()["access_token"]}
    phone = "199" + f"{uuid.uuid4().int % 100_000_000:08d}"
    password = "Integration-account-password-2026"
    created = await http_client.post(
        "/api/admin/users",
        headers=admin_headers,
        json={
            "phone": phone,
            "display_name": "HTTP MCP integration patient",
            "role": "patient",
            "password": password,
            "timezone": "UTC",
        },
    )
    assert created.status_code == 201
    patient = created.json()
    patient_login = await http_client.post(
        "/api/auth/password", json={"username": phone, "password": password}
    )
    assert patient_login.status_code == 200
    patient_headers = {
        "Authorization": "Bearer " + patient_login.json()["access_token"]
    }
    created_plan = await http_client.post(
        "/api/plans",
        headers=patient_headers,
        json={
            "drug_name": "Integration medication",
            "dosage": "1 tablet",
            "times": ["00:00"],
        },
    )
    assert created_plan.status_code == 201
    plan_id = created_plan.json()["id"]
    listed_doses = await http_client.get(
        "/api/doses",
        headers=patient_headers,
        params={"date": datetime.now(timezone.utc).date().isoformat()},
    )
    assert listed_doses.status_code == 200
    assert len(listed_doses.json()) == 1
    dose_id = listed_doses.json()[0]["id"]
    created_binding = await http_client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": patient["id"], "label": "Official SDK integration"},
    )
    assert created_binding.status_code == 201
    binding = created_binding.json()
    parameters = StdioServerParameters(
        command=sys.executable,
        args=["-m", "app.mcp_server"],
        env={
            "WAKEMATE_API_URL": api_url,
            "WAKEMATE_MCP_TOKEN": binding["token"],
            "PYTHONPATH": str(Path(__file__).resolve().parents[1]),
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    )
    with tempfile.TemporaryFile(mode="w+") as stderr:
        async with stdio_client(parameters, errlog=stderr) as (read, write):
            async with ClientSession(
                read, write, read_timeout_seconds=timedelta(seconds=10)
            ) as session:
                initialized = await session.initialize()
                assert initialized.serverInfo.name == "wakemate-readonly"
                tools = (await session.list_tools()).tools
                assert {tool.name for tool in tools} == {
                    "get_today_doses",
                    "get_dose_status",
                    "get_recent_medication_history",
                    "get_medication_plans",
                    "get_device_status",
                }
                assert all(tool.annotations.readOnlyHint for tool in tools)
                initial = _tool_data(
                    await session.call_tool(
                        "get_dose_status", {"dose_instance_id": dose_id}
                    )
                )["dose"]
                assert initial["id"] == dose_id
                assert initial["status"] == "pending"

                confirmed = await http_client.post(
                    "/api/records/confirm",
                    headers={**patient_headers, "Idempotency-Key": uuid.uuid4().hex},
                    json={"dose_instance_id": dose_id, "confirmed_by": "user_tap"},
                )
                assert confirmed.status_code == 200
                records = await http_client.get("/api/records", headers=patient_headers)
                assert records.status_code == 200
                assert len(records.json()) == 1
                saved_record = records.json()[0]
                assert saved_record["id"] == dose_id
                assert saved_record["status"] == "confirmed"

                live_dose = _tool_data(
                    await session.call_tool(
                        "get_dose_status", {"dose_instance_id": dose_id}
                    )
                )["dose"]
                assert live_dose["id"] == dose_id
                assert live_dose["status"] == "confirmed"
                assert live_dose["actual_time"] == saved_record["actual_time"]
                today = _tool_data(await session.call_tool("get_today_doses", {}))[
                    "doses"
                ]
                assert today[0]["id"] == dose_id
                assert today[0]["status"] == "confirmed"
                history = _tool_data(
                    await session.call_tool(
                        "get_recent_medication_history", {"days": 7}
                    )
                )["records"]
                assert any(
                    record["id"] == dose_id and record["status"] == "confirmed"
                    for record in history
                )
                plans = _tool_data(await session.call_tool("get_medication_plans", {}))[
                    "plans"
                ]
                assert [plan["id"] for plan in plans] == [plan_id]

                revoked = await http_client.post(
                    f"/api/admin/mcp-bindings/{binding['id']}/revoke",
                    headers=admin_headers,
                )
                assert revoked.status_code == 200
                denied = await session.call_tool(
                    "get_dose_status", {"dose_instance_id": dose_id}
                )
                assert denied.isError
                assert json.loads(denied.content[0].text)["error"] == "access_denied"
        stderr.seek(0)
        token_leaked = binding["token"] in stderr.read()
        assert not token_leaked, "MCP binding token leaked to stderr"
