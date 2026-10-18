"""Exercise actual MCP transports and a real loopback HTTP service."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
import websockets

from app.mcp_connector import ConnectorConfig, healthcheck, run_connector
from app.mcp_server import APIConfig

TEST_TOKEN = "mcp-test-binding-token"
ENDPOINT_SECRET = "endpoint-test-secret"


@pytest.fixture
def medication_api():
    state = {"calls": [], "authorized": True, "invalid_response": False}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            state["calls"].append((self.path, body))
            authorized = (
                state["authorized"]
                and self.headers.get("Authorization") == f"Bearer {TEST_TOKEN}"
            )
            if not authorized:
                result, status = (
                    {"detail": "Private server detail must never be returned"},
                    403,
                )
            elif state["invalid_response"]:
                result, status = [], 200
            elif self.path.endswith("get_dose_status"):
                result, status = (
                    {
                        "dose": {
                            "dose_instance_id": body["dose_instance_id"],
                            "status": "unconfirmed",
                        }
                    },
                    200,
                )
            else:
                result, status = (
                    {
                        "doses": [
                            {"dose_instance_id": "dose-owned", "status": "unconfirmed"}
                        ]
                    },
                    200,
                )
            data = json.dumps(result).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    service = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=service.serve_forever, daemon=True)
    worker.start()
    try:
        yield f"http://127.0.0.1:{service.server_port}", state
    finally:
        service.shutdown()
        service.server_close()
        worker.join(timeout=5)


def request(identifier: int, method: str, params: dict | None = None) -> dict:
    result = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        result["params"] = params
    return result


INITIALIZE = {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "integration-test", "version": "1.0.0"},
}


async def websocket_rpc(websocket, message: dict) -> dict:
    await websocket.send(json.dumps(message))
    response = json.loads(await asyncio.wait_for(websocket.recv(), timeout=5))
    assert response["id"] == message["id"]
    return response


async def initialize_websocket(websocket) -> None:
    result = await websocket_rpc(websocket, request(1, "initialize", INITIALIZE))
    assert result["result"]["serverInfo"]["name"] == "wakemate-readonly"
    await websocket.send(
        json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})
    )


def test_outbound_connector_protocol_reconnect_and_binding_revocation(
    medication_api, tmp_path, caplog
):
    api_url, state = medication_api
    caplog.set_level(logging.INFO)

    async def scenario():
        stop = asyncio.Event()
        reconnected = asyncio.Event()
        failures = []
        connections = 0
        status_file = tmp_path / "mcp-status.json"

        async def endpoint(websocket):
            nonlocal connections
            connections += 1
            try:
                await initialize_websocket(websocket)
                if connections == 2:
                    assert (await websocket_rpc(websocket, request(2, "ping")))[
                        "result"
                    ] == {}
                    reconnected.set()
                    await stop.wait()
                    return
                assert healthcheck(status_file)
                assert (await websocket_rpc(websocket, request(2, "ping")))[
                    "result"
                ] == {}
                listed = await websocket_rpc(websocket, request(3, "tools/list", {}))
                tools = listed["result"]["tools"]
                assert {tool["name"] for tool in tools} == {
                    "get_today_doses",
                    "get_dose_status",
                    "get_recent_medication_history",
                    "get_medication_plans",
                    "get_device_status",
                }
                assert all(
                    tool["inputSchema"]["additionalProperties"] is False
                    for tool in tools
                )
                assert all(tool["annotations"]["readOnlyHint"] for tool in tools)
                called = await websocket_rpc(
                    websocket,
                    request(
                        4, "tools/call", {"name": "get_today_doses", "arguments": {}}
                    ),
                )
                assert not called["result"]["isError"]
                assert (
                    json.loads(called["result"]["content"][0]["text"])["doses"][0][
                        "dose_instance_id"
                    ]
                    == "dose-owned"
                )
                before_invalid = len(state["calls"])
                for identifier, extra in enumerate(
                    ("patient_id", "user_id", "tenant_id"), start=5
                ):
                    denied = await websocket_rpc(
                        websocket,
                        request(
                            identifier,
                            "tools/call",
                            {
                                "name": "get_today_doses",
                                "arguments": {extra: "other-patient"},
                            },
                        ),
                    )
                    assert denied["result"]["isError"]
                invalid_days = await websocket_rpc(
                    websocket,
                    request(
                        8,
                        "tools/call",
                        {
                            "name": "get_recent_medication_history",
                            "arguments": {"days": 91},
                        },
                    ),
                )
                assert invalid_days["result"]["isError"]
                assert len(state["calls"]) == before_invalid
                dose = await websocket_rpc(
                    websocket,
                    request(
                        9,
                        "tools/call",
                        {
                            "name": "get_dose_status",
                            "arguments": {"dose_instance_id": "dose-owned"},
                        },
                    ),
                )
                assert (
                    dose["result"]["structuredContent"]["dose"]["status"]
                    == "unconfirmed"
                )
                await websocket_rpc(
                    websocket,
                    request(
                        10,
                        "tools/call",
                        {"name": "get_recent_medication_history", "arguments": {}},
                    ),
                )
                assert state["calls"][-1][1] == {"days": 7}
                state["invalid_response"] = True
                invalid = await websocket_rpc(
                    websocket,
                    request(
                        11, "tools/call", {"name": "get_today_doses", "arguments": {}}
                    ),
                )
                assert invalid["result"]["isError"]
                state["invalid_response"] = False
                state["authorized"] = False
                denied = await websocket_rpc(
                    websocket,
                    request(
                        12, "tools/call", {"name": "get_today_doses", "arguments": {}}
                    ),
                )
                assert denied["result"]["isError"]
                assert "access_denied" in denied["result"]["content"][0]["text"]
                assert "Private server detail" not in json.dumps(denied)
                unknown = await websocket_rpc(
                    websocket,
                    request(
                        13,
                        "tools/call",
                        {"name": "confirm_medication", "arguments": {}},
                    ),
                )
                assert unknown["result"]["isError"]
                await websocket.close()
            except Exception as exc:
                failures.append(exc)
                stop.set()

        async with websockets.serve(endpoint, "127.0.0.1", 0) as service:
            port = service.sockets[0].getsockname()[1]
            config = ConnectorConfig.from_env(
                {
                    "WAKEMATE_API_URL": api_url,
                    "WAKEMATE_MCP_TOKEN": TEST_TOKEN,
                    "MCP_ENDPOINT": f"ws://127.0.0.1:{port}/mcp?token={ENDPOINT_SECRET}",
                    "WAKEMATE_MCP_STATUS_FILE": str(status_file),
                }
            )
            connector = asyncio.create_task(
                run_connector(config, stop, retry_initial=0.01, retry_max=0.02)
            )
            try:
                await asyncio.wait_for(reconnected.wait(), timeout=15)
            finally:
                stop.set()
                await asyncio.wait_for(connector, timeout=5)
            assert not failures, failures
            assert connections == 2
            assert not healthcheck(status_file)
            assert json.loads(status_file.read_text())["state"] == "stopped"
            assert ENDPOINT_SECRET not in status_file.read_text()
            assert TEST_TOKEN not in repr(config)
            assert ENDPOINT_SECRET not in repr(config)

    asyncio.run(scenario())
    assert TEST_TOKEN not in caplog.text
    assert ENDPOINT_SECRET not in caplog.text
    assert api_url not in caplog.text


def test_stdio_transport_uses_authenticated_api(medication_api):
    api_url, state = medication_api

    async def scenario():
        env = os.environ.copy()
        env.update({"WAKEMATE_API_URL": api_url, "WAKEMATE_MCP_TOKEN": TEST_TOKEN})
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "app.mcp_server",
            cwd=Path(__file__).resolve().parents[1],
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        async def exchange(message):
            process.stdin.write((json.dumps(message) + "\n").encode())
            await process.stdin.drain()
            response = json.loads(
                await asyncio.wait_for(process.stdout.readline(), timeout=10)
            )
            assert response["id"] == message["id"]
            return response

        try:
            initialized = await exchange(request(1, "initialize", INITIALIZE))
            assert initialized["result"]["serverInfo"]["name"] == "wakemate-readonly"
            process.stdin.write(
                b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
            )
            await process.stdin.drain()
            tools = await exchange(request(2, "tools/list", {}))
            assert len(tools["result"]["tools"]) == 5
            result = await exchange(
                request(3, "tools/call", {"name": "get_today_doses", "arguments": {}})
            )
            assert not result["result"]["isError"]
            assert state["calls"][-1] == ("/api/mcp/tools/get_today_doses", {})
        finally:
            process.stdin.close()
            try:
                await asyncio.wait_for(process.wait(), timeout=5)
            except TimeoutError:
                process.kill()
                await process.wait()
        assert process.returncode == 0
        stderr = (await process.stderr.read()).decode()
        assert TEST_TOKEN not in stderr
        assert api_url not in stderr

    asyncio.run(scenario())


def test_required_configuration_and_secure_endpoint():
    with pytest.raises(ValueError, match="WAKEMATE_MCP_TOKEN is required"):
        APIConfig.from_env({})
    with pytest.raises(ValueError, match="MCP_ENDPOINT is required"):
        ConnectorConfig.from_env({"WAKEMATE_MCP_TOKEN": TEST_TOKEN})
    with pytest.raises(ValueError, match="must use WSS"):
        ConnectorConfig.from_env(
            {
                "WAKEMATE_MCP_TOKEN": TEST_TOKEN,
                "MCP_ENDPOINT": "ws://remote.example/mcp",
            }
        )
    with pytest.raises(ValueError, match=r"HTTP\(S\) base URL"):
        APIConfig.from_env(
            {
                "WAKEMATE_MCP_TOKEN": TEST_TOKEN,
                "WAKEMATE_API_URL": "https://secret@remote.example/api",
            }
        )


def test_missing_token_fails_before_starting_transport():
    async def scenario():
        env = os.environ.copy()
        env.pop("WAKEMATE_MCP_TOKEN", None)
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "app.mcp_server",
            cwd=Path(__file__).resolve().parents[1],
            env=env,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=10)
        assert process.returncode == 1
        assert not stdout
        assert b"WAKEMATE_MCP_TOKEN is required" in stderr

    asyncio.run(scenario())


@pytest.mark.skipif(
    sys.platform == "win32", reason="Graceful SIGTERM is verified inside Linux Docker."
)
def test_connector_process_stops_cleanly_on_sigterm(medication_api, tmp_path):
    api_url, _ = medication_api

    async def scenario():
        ready = asyncio.Event()
        status_file = tmp_path / "process-status.json"

        async def endpoint(websocket):
            await initialize_websocket(websocket)
            ready.set()
            await websocket.wait_closed()

        async with websockets.serve(endpoint, "127.0.0.1", 0) as service:
            port = service.sockets[0].getsockname()[1]
            env = os.environ.copy()
            env.update(
                {
                    "WAKEMATE_API_URL": api_url,
                    "WAKEMATE_MCP_TOKEN": TEST_TOKEN,
                    "MCP_ENDPOINT": f"ws://127.0.0.1:{port}/mcp?token={ENDPOINT_SECRET}",
                    "WAKEMATE_MCP_STATUS_FILE": str(status_file),
                }
            )
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "app.mcp_connector",
                cwd=Path(__file__).resolve().parents[1],
                env=env,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                await asyncio.wait_for(ready.wait(), timeout=10)
                assert healthcheck(status_file)
                process.send_signal(signal.SIGTERM)
                stdout, stderr = await asyncio.wait_for(
                    process.communicate(), timeout=10
                )
            finally:
                if process.returncode is None:
                    process.kill()
                    await process.wait()
            assert process.returncode == 0
            assert not stdout
            assert TEST_TOKEN.encode() not in stderr
            assert ENDPOINT_SECRET.encode() not in stderr
            assert json.loads(status_file.read_text())["state"] == "stopped"

    asyncio.run(scenario())
