"""Outbound XiaoZhi WebSocket transport for the read-only MCP server."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from collections.abc import Awaitable, Callable
from typing import Mapping
from urllib.parse import urlsplit

import anyio
import mcp.types as types
import websockets
from mcp.server.lowlevel import Server
from mcp.shared.message import SessionMessage
from pydantic import ValidationError

from app.mcp_server import APIConfig, build_server, configure_logging

logger = logging.getLogger("wakemate.mcp.connector")
StateObserver = Callable[[str, str | None], Awaitable[None]]


def status_path(environ: Mapping[str, str] | None = None) -> Path:
    env = os.environ if environ is None else environ
    return Path(
        env.get(
            "WAKEMATE_MCP_STATUS_FILE",
            str(Path(tempfile.gettempdir()) / "wakemate-mcp-status.json"),
        )
    )


@dataclass(frozen=True)
class ConnectorConfig:
    api: APIConfig
    endpoint: str = field(repr=False)
    status_file: Path

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "ConnectorConfig":
        env = os.environ if environ is None else environ
        api = APIConfig.from_env(env)
        endpoint = env.get("MCP_ENDPOINT", "").strip()
        if not endpoint:
            raise ValueError("MCP_ENDPOINT is required")
        try:
            parsed = urlsplit(endpoint)
            secure = parsed.scheme == "wss"
            local = parsed.scheme == "ws" and parsed.hostname in {
                "localhost",
                "127.0.0.1",
                "::1",
            }
            valid = (
                (secure or local)
                and parsed.hostname
                and not parsed.username
                and not parsed.password
                and not parsed.fragment
            )
            parsed.port
        except ValueError:
            valid = False
        if not valid:
            raise ValueError(
                "MCP_ENDPOINT must use WSS (WS is allowed only on loopback for local tests)"
            )
        return cls(api=api, endpoint=endpoint, status_file=status_path(env))


def write_status(path: Path, state: str, attempt: int = 0) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps({"state": state, "updated_at": time.time(), "attempt": attempt}),
        encoding="utf-8",
    )
    temporary.replace(path)


def healthcheck(path: Path, max_age: float = 45.0) -> bool:
    try:
        status = json.loads(path.read_text(encoding="utf-8"))
        age = time.time() - status["updated_at"]
        return status["state"] == "connected" and 0 <= age < max_age
    except (OSError, ValueError, KeyError, TypeError):
        return False


async def publish_status(
    path: Path,
    state: str,
    attempt: int = 0,
    observer: StateObserver | None = None,
    error: str | None = None,
) -> None:
    write_status(path, state, attempt)
    if observer is not None:
        await observer(state, error)


async def serve_websocket(
    websocket,
    server: Server,
    status_file: Path,
    observer: StateObserver | None = None,
) -> None:
    inbound_writer, inbound = anyio.create_memory_object_stream(16)
    outbound, outbound_reader = anyio.create_memory_object_stream(16)

    async with anyio.create_task_group() as group:

        async def read_messages() -> None:
            try:
                async with inbound_writer:
                    async for frame in websocket:
                        try:
                            message = types.JSONRPCMessage.model_validate_json(frame)
                        except ValidationError:
                            # Never pass raw validation errors containing input frames into SDK logs.
                            await inbound_writer.send(
                                ValueError("Invalid JSON-RPC message")
                            )
                            continue
                        await inbound_writer.send(SessionMessage(message))
            finally:
                group.cancel_scope.cancel()

        async def write_messages() -> None:
            async with outbound_reader:
                async for message in outbound_reader:
                    await websocket.send(
                        message.message.model_dump_json(
                            by_alias=True, exclude_none=True
                        )
                    )

        async def heartbeat() -> None:
            while True:
                await publish_status(status_file, "connected", observer=observer)
                await anyio.sleep(10)

        async with inbound, outbound:
            group.start_soon(read_messages)
            group.start_soon(write_messages)
            group.start_soon(heartbeat)
            await server.run(inbound, outbound, server.create_initialization_options())
            group.cancel_scope.cancel()


async def _connect(
    config: ConnectorConfig, observer: StateObserver | None = None
) -> None:
    async with websockets.connect(
        config.endpoint,
        open_timeout=15,
        close_timeout=5,
        ping_interval=20,
        ping_timeout=20,
        max_size=1024 * 1024,
        max_queue=16,
        proxy=None,
    ) as websocket:
        logger.info("MCP endpoint connected")
        await serve_websocket(
            websocket, build_server(config.api), config.status_file, observer
        )


async def run_connector(
    config: ConnectorConfig,
    stop: asyncio.Event | None = None,
    retry_initial: float = 1.0,
    retry_max: float = 60.0,
    observer: StateObserver | None = None,
    retry_heartbeat: float = 10.0,
) -> None:
    configure_logging()
    stop = stop if stop is not None else asyncio.Event()
    delay = retry_initial
    attempt = 0
    await publish_status(config.status_file, "starting", observer=observer)
    try:
        while not stop.is_set():
            await publish_status(config.status_file, "connecting", attempt, observer)
            session = asyncio.create_task(_connect(config, observer))
            stopping = asyncio.create_task(stop.wait())
            error = None
            try:
                done, _ = await asyncio.wait(
                    {session, stopping}, return_when=asyncio.FIRST_COMPLETED
                )
                if stopping in done:
                    break
                try:
                    await session
                except Exception as exc:
                    error = type(exc).__name__
                    logger.warning(
                        "MCP endpoint disconnected error=%s", type(exc).__name__
                    )
                else:
                    error = "transport_closed"
                    logger.warning("MCP endpoint disconnected")
            finally:
                session.cancel()
                stopping.cancel()
                await asyncio.gather(session, stopping, return_exceptions=True)
            if stop.is_set():
                break
            attempt += 1
            await publish_status(
                config.status_file, "retrying", attempt, observer, error
            )
            logger.info("Reconnecting attempt=%s delay_seconds=%s", attempt, delay)
            # Keep the observed retry state fresh throughout long backoff periods.
            # Heartbeats do not shorten the deadline or start another connection.
            loop = asyncio.get_running_loop()
            deadline = loop.time() + delay
            while not stop.is_set():
                remaining = deadline - loop.time()
                if remaining <= 0:
                    break
                try:
                    await asyncio.wait_for(
                        stop.wait(), timeout=min(remaining, retry_heartbeat)
                    )
                except TimeoutError:
                    if loop.time() < deadline:
                        await publish_status(
                            config.status_file, "retrying", attempt, observer, error
                        )
            delay = min(delay * 2, retry_max)
    finally:
        await publish_status(config.status_file, "stopped", attempt, observer)


async def run_until_signal(config: ConnectorConfig) -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            signal.signal(sig, lambda *_: loop.call_soon_threadsafe(stop.set))
    await run_connector(config, stop)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Connect WakeMate read-only tools to a XiaoZhi MCP endpoint"
    )
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()
    if args.healthcheck:
        return 0 if healthcheck(status_path()) else 1
    configure_logging()
    try:
        config = ConnectorConfig.from_env()
    except ValueError as exc:
        logger.error("Configuration error: %s", exc)
        return 1
    try:
        asyncio.run(run_until_signal(config))
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        logger.error("MCP connector stopped: %s", type(exc).__name__)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
