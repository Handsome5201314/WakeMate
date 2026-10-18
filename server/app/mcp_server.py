"""Read-only MCP tools backed by the authenticated WakeMate API."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Mapping
from urllib.parse import urlsplit

import httpx
import mcp.types as types
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server

logger = logging.getLogger("wakemate.mcp")


@dataclass(frozen=True)
class APIConfig:
    api_url: str
    token: str = field(repr=False)
    timeout: float = 15.0

    @classmethod
    def from_env(cls, environ: Mapping[str, str] | None = None) -> "APIConfig":
        env = os.environ if environ is None else environ
        token = env.get("WAKEMATE_MCP_TOKEN", "").strip()
        if not token:
            raise ValueError("WAKEMATE_MCP_TOKEN is required")
        api_url = env.get("WAKEMATE_API_URL", "http://api:8000").rstrip("/")
        try:
            parsed = urlsplit(api_url)
            valid = (
                parsed.scheme in {"http", "https"}
                and parsed.hostname
                and not parsed.username
                and not parsed.password
                and not parsed.query
                and not parsed.fragment
            )
            parsed.port
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("WAKEMATE_API_URL must be an HTTP(S) base URL")
        return cls(api_url=api_url, token=token)


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")
    # Transport/library debug logs can contain requests, tokens, or patient data.
    for name in ("mcp", "httpx", "httpcore", "websockets"):
        logging.getLogger(name).setLevel(logging.CRITICAL)


def _schema(properties: dict | None = None, required: list[str] | None = None) -> dict:
    schema = {
        "type": "object",
        "properties": properties or {},
        "additionalProperties": False,
    }
    if required:
        schema["required"] = required
    return schema


def tool_definitions() -> list[types.Tool]:
    definitions = [
        (
            "get_today_doses",
            "Read today's dose instances for the patient bound to this connection. "
            "No confirmation does not prove a missed dose; opening a box does not prove ingestion.",
            _schema(),
        ),
        (
            "get_dose_status",
            "Read a specific dose instance for the bound patient, including its evidence and status.",
            _schema(
                {
                    "dose_instance_id": {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 128,
                    }
                },
                ["dose_instance_id"],
            ),
        ),
        (
            "get_recent_medication_history",
            "Read recent medication records for the bound patient. Days defaults to 7, maximum 90.",
            _schema(
                {"days": {"type": "integer", "minimum": 1, "maximum": 90, "default": 7}}
            ),
        ),
        (
            "get_medication_plans",
            "Read the bound patient's medication plans. Do not change prescriptions or dose schedules.",
            _schema(),
        ),
        (
            "get_device_status",
            "Read all WakeMate devices registered and claimed by this patient, "
            "not the Xiaozhi console's phone/board list or the current speaking terminal. "
            "Connection status is not medication-taking evidence.",
            _schema(),
        ),
    ]
    return [
        types.Tool(
            name=name,
            description=description,
            inputSchema=schema,
            annotations=types.ToolAnnotations(
                readOnlyHint=True,
                destructiveHint=False,
                idempotentHint=True,
                openWorldHint=False,
            ),
        )
        for name, description, schema in definitions
    ]


def _tool_error(code: str, message: str) -> types.CallToolResult:
    return types.CallToolResult(
        content=[
            types.TextContent(
                type="text", text=json.dumps({"error": code, "message": message})
            )
        ],
        isError=True,
    )


def build_server(config: APIConfig) -> Server:
    @asynccontextmanager
    async def lifespan(_: Server):
        async with httpx.AsyncClient(
            headers={"Authorization": f"Bearer {config.token}"},
            timeout=config.timeout,
            follow_redirects=False,
            trust_env=False,
        ) as client:
            yield {"api_client": client}

    server = Server("wakemate-readonly", version="1.0.0", lifespan=lifespan)
    definitions = tool_definitions()
    names = {tool.name for tool in definitions}

    @server.list_tools()
    async def list_tools() -> list[types.Tool]:
        return definitions

    @server.call_tool(validate_input=True)
    async def call_tool(name: str, arguments: dict | None) -> types.CallToolResult:
        if name not in names:
            return _tool_error("unknown_tool", "This tool is not available.")
        payload = dict(arguments or {})
        if name == "get_recent_medication_history":
            payload.setdefault("days", 7)
        client: httpx.AsyncClient = server.request_context.lifespan_context[
            "api_client"
        ]
        try:
            response = await client.post(
                f"{config.api_url}/api/mcp/tools/{name}", json=payload
            )
        except httpx.TimeoutException:
            logger.warning("API timeout tool=%s", name)
            return _tool_error(
                "service_timeout", "The medication service timed out. Please try again."
            )
        except httpx.RequestError:
            logger.warning("API unavailable tool=%s", name)
            return _tool_error(
                "service_unavailable",
                "The medication service is unavailable. Please try again.",
            )

        if not response.is_success:
            logger.warning("API rejected tool=%s status=%s", name, response.status_code)
            if response.status_code in {401, 403}:
                return _tool_error(
                    "access_denied",
                    "This connection has no active patient authorization.",
                )
            if response.status_code == 404:
                return _tool_error(
                    "not_found",
                    "The requested dose or resource is unavailable for this patient.",
                )
            return _tool_error(
                "service_error",
                f"The medication service rejected the request (HTTP {response.status_code}).",
            )
        try:
            result = response.json()
        except ValueError:
            return _tool_error(
                "invalid_response",
                "The medication service returned an invalid response.",
            )
        if not isinstance(result, dict):
            return _tool_error(
                "invalid_response",
                "The medication service returned an invalid response.",
            )
        logger.info("Tool completed tool=%s", name)
        return types.CallToolResult(
            content=[
                types.TextContent(
                    type="text", text=json.dumps(result, ensure_ascii=False)
                )
            ],
            structuredContent=result,
            isError=False,
        )

    return server


async def run_stdio(config: APIConfig) -> None:
    configure_logging()
    server = build_server(config)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream, write_stream, server.create_initialization_options()
        )


def main() -> int:
    configure_logging()
    try:
        config = APIConfig.from_env()
    except ValueError as exc:
        logger.error("Configuration error: %s", exc)
        return 1
    try:
        asyncio.run(run_stdio(config))
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        logger.error("MCP server stopped: %s", type(exc).__name__)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
