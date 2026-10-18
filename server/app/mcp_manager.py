"""Maintain one outbound MCP connection per active, persisted patient binding."""

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

from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.db import Session
from app.mcp_connections import open_config
from app.mcp_connector import ConnectorConfig, run_connector, write_status
from app.mcp_server import configure_logging
from app.models import Binding, MCPConnection, User, utcnow

logger = logging.getLogger("wakemate.mcp.manager")


def status_path() -> Path:
    return Path(
        os.environ.get(
            "WAKEMATE_MCP_MANAGER_STATUS_FILE",
            str(Path(tempfile.gettempdir()) / "wakemate-mcp-manager-status.json"),
        )
    )


def healthcheck(path: Path, max_age: float = 15.0) -> bool:
    try:
        status = json.loads(path.read_text(encoding="utf-8"))
        age = time.time() - status["updated_at"]
        return status["state"] == "running" and 0 <= age < max_age
    except (OSError, ValueError, KeyError, TypeError):
        return False


@dataclass(frozen=True)
class ConnectionSnapshot:
    binding_id: str
    generation: int
    encrypted_config: str = field(repr=False)


@dataclass
class RunningConnection:
    snapshot: ConnectionSnapshot
    task: asyncio.Task


async def connection_snapshots(
    sessions: async_sessionmaker,
) -> dict[str, ConnectionSnapshot]:
    async with sessions() as db:
        rows = (
            await db.execute(
                select(
                    MCPConnection.binding_id,
                    MCPConnection.generation,
                    MCPConnection.encrypted_config,
                )
                .join(Binding, Binding.id == MCPConnection.binding_id)
                .join(User, User.id == Binding.patient_id)
                .where(Binding.active, User.active, User.role == "patient")
            )
        ).all()
    return {row.binding_id: ConnectionSnapshot(*row) for row in rows}


async def record_state(
    sessions: async_sessionmaker,
    snapshot: ConnectionSnapshot,
    state: str,
    error: str | None = None,
) -> None:
    """Ignore late callbacks from a replaced or deleted connection generation."""
    now = utcnow()
    values = {
        "state": "queued" if state == "starting" else state,
        "updated_at": now,
        "last_error": error,
        "heartbeat": now,
    }
    async with sessions() as db:
        await db.execute(
            update(MCPConnection)
            .where(
                MCPConnection.binding_id == snapshot.binding_id,
                MCPConnection.generation == snapshot.generation,
                MCPConnection.encrypted_config == snapshot.encrypted_config,
            )
            .values(**values)
        )
        if state == "connected":
            await db.execute(
                update(MCPConnection)
                .where(
                    MCPConnection.binding_id == snapshot.binding_id,
                    MCPConnection.generation == snapshot.generation,
                    MCPConnection.encrypted_config == snapshot.encrypted_config,
                    MCPConnection.connected_at.is_(None),
                )
                .values(connected_at=now)
            )
        await db.commit()


async def stop_connection(connection: RunningConnection) -> None:
    connection.task.cancel()
    results = await asyncio.gather(connection.task, return_exceptions=True)
    for result in results:
        if isinstance(result, Exception):
            logger.warning("Connector shutdown failed error=%s", type(result).__name__)


async def run_manager(
    sessions: async_sessionmaker = Session,
    stop: asyncio.Event | None = None,
    *,
    api_url: str = "http://api:8000",
    status_file: Path | None = None,
    poll_interval: float = 2.0,
    retry_initial: float = 1.0,
    retry_max: float = 60.0,
    retry_heartbeat: float = 10.0,
    allow_loopback: bool = False,
) -> None:
    """Read only DB configuration; no global endpoint or patient token is used."""
    configure_logging()
    stop = stop if stop is not None else asyncio.Event()
    status_file = status_file if status_file is not None else status_path()
    running: dict[str, RunningConnection] = {}
    invalid: dict[str, ConnectionSnapshot] = {}
    engine = sessions.kw["bind"]
    async with engine.connect() as lock:
        identity = (
            await lock.execute(
                text(
                    "SELECT hashtextextended('wakemate:mcp-manager:' || "
                    "current_database() || ':' || current_schema(), 0) AS lock_key, "
                    "pg_backend_pid() AS backend_id"
                )
            )
        ).one()
        lock_key, backend_id = identity.lock_key, identity.backend_id
        # Session lock survives commits; keep its connection checked out.
        acquired = await lock.scalar(
            text("SELECT pg_try_advisory_lock(:key)"), {"key": lock_key}
        )
        await lock.commit()
        if not acquired:
            raise RuntimeError("Another MCP manager owns the database lock")
        try:
            while not stop.is_set():
                # A lost lock connection stops this manager before it starts more workers.
                if lock.invalidated:
                    raise RuntimeError("MCP manager lost its database lock connection")
                current_backend = await lock.scalar(text("SELECT pg_backend_pid()"))
                if current_backend != backend_id:
                    raise RuntimeError("MCP manager database lock session changed")
                await lock.commit()
                desired = await connection_snapshots(sessions)
                for binding_id, connection in list(running.items()):
                    current = desired.get(binding_id)
                    if current != connection.snapshot or connection.task.done():
                        if connection.task.done() and current == connection.snapshot:
                            try:
                                connection.task.result()
                            except asyncio.CancelledError:
                                pass
                            except Exception as exc:
                                logger.warning(
                                    "Connector task stopped error=%s",
                                    type(exc).__name__,
                                )
                        await stop_connection(connection)
                        del running[binding_id]
                invalid = {
                    key: snapshot
                    for key, snapshot in invalid.items()
                    if desired.get(key) == snapshot
                }
                for binding_id, snapshot in desired.items():
                    if binding_id in running or invalid.get(binding_id) == snapshot:
                        continue
                    try:
                        stored = open_config(
                            snapshot.encrypted_config, allow_loopback=allow_loopback
                        )
                        config = ConnectorConfig.from_env(
                            {
                                "WAKEMATE_API_URL": api_url,
                                "WAKEMATE_MCP_TOKEN": stored["api_token"],
                                "MCP_ENDPOINT": stored["endpoint"],
                                "WAKEMATE_MCP_STATUS_FILE": str(
                                    status_file.parent
                                    / "mcp-bindings"
                                    / f"{binding_id}.json"
                                ),
                            }
                        )
                    except Exception:
                        # Ciphertext/URL/token exceptions may contain private values.
                        await record_state(
                            sessions, snapshot, "error", "config_invalid"
                        )
                        invalid[binding_id] = snapshot
                        logger.warning("Binding configuration invalid")
                        continue

                    async def observer(state, error, bound=snapshot):
                        await record_state(sessions, bound, state, error)

                    task = asyncio.create_task(
                        run_connector(
                            config,
                            retry_initial=retry_initial,
                            retry_max=retry_max,
                            observer=observer,
                            retry_heartbeat=retry_heartbeat,
                        ),
                        name=f"mcp-binding-{binding_id}",
                    )
                    running[binding_id] = RunningConnection(snapshot, task)
                write_status(status_file, "running")
                try:
                    await asyncio.wait_for(stop.wait(), timeout=poll_interval)
                except TimeoutError:
                    pass
        finally:
            for connection in running.values():
                await stop_connection(connection)
            write_status(status_file, "stopped")
            try:
                await lock.execute(
                    text("SELECT pg_advisory_unlock(:key)"), {"key": lock_key}
                )
                await lock.commit()
            except Exception as exc:
                logger.warning(
                    "Manager lock release failed error=%s", type(exc).__name__
                )
                # Never return a session with an unreleased advisory lock to the pool.
                await lock.invalidate()


async def run_until_signal() -> None:
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            signal.signal(sig, lambda *_: loop.call_soon_threadsafe(stop.set))
    await run_manager(stop=stop)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Manage persisted XiaoZhi MCP connections"
    )
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()
    if args.healthcheck:
        return 0 if healthcheck(status_path()) else 1
    configure_logging()
    try:
        asyncio.run(run_until_signal())
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        logger.error("MCP manager stopped error=%s", type(exc).__name__)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
