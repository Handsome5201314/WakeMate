"""Store official XiaoZhi endpoints without exposing their credentials to the UI."""

import base64
import hashlib
import hmac
import json
from urllib.parse import parse_qsl, urlsplit

from cryptography.fernet import Fernet
from fastapi import HTTPException
from sqlalchemy import func, select, text

from app.config import get_settings
from app.models import MCPConnection, utcnow

MAX_CONNECTIONS = 16
# Serializes configuration writes and the capacity check across API processes.
CONFIGURATION_LOCK = 634385777


def validate_endpoint(endpoint: str) -> str:
    message = "请粘贴小智控制台提供的完整 MCP 接入点地址（wss://api.xiaozhi.me/mcp/?token=…）"
    try:
        if not endpoint or len(endpoint) > 4096:
            raise ValueError("length")
        if any(ord(c) <= 32 or ord(c) == 127 for c in endpoint) or "#" in endpoint:
            raise ValueError("characters")
        parsed = urlsplit(endpoint)
        if (
            parsed.scheme != "wss"
            or parsed.netloc.lower() not in {"api.xiaozhi.me", "api.xiaozhi.me:443"}
            or parsed.path not in {"/mcp", "/mcp/"}
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise ValueError("origin")
        pairs = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
        if len(pairs) != 1 or pairs[0][0] != "token" or not pairs[0][1]:
            raise ValueError("token")
        if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in pairs[0][1]):
            raise ValueError("token characters")
    except (ValueError, TypeError):
        # The endpoint is a credential. Never include it in error text or logs.
        raise HTTPException(422, message) from None
    return endpoint


def _cipher() -> Fernet:
    material = get_settings().secret.encode() + b":wakemate:mcp-connections:v1"
    return Fernet(base64.urlsafe_b64encode(hashlib.sha256(material).digest()))


def _validate_config_endpoint(endpoint: str, allow_loopback: bool):
    if not allow_loopback:
        validate_endpoint(endpoint)
        return
    # Test-only function argument; it is never set by HTTP, CLI, or environment.
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme == "ws"
        and parsed.hostname in {"localhost", "127.0.0.1", "::1"}
        and parsed.username is None
        and parsed.password is None
        and "#" not in endpoint
        and not any(ord(c) <= 32 or ord(c) == 127 for c in endpoint)
    ):
        return
    validate_endpoint(endpoint)


def endpoint_hash(endpoint: str, *, allow_loopback: bool = False) -> str:
    _validate_config_endpoint(endpoint, allow_loopback)
    parsed = urlsplit(endpoint)
    if allow_loopback and parsed.scheme == "ws":
        identity = endpoint
    else:
        # The origin/path variants all reach the same official endpoint. The
        # decoded token identifies it, so escaping/case/:443 cannot bypass reuse.
        identity = parse_qsl(parsed.query, keep_blank_values=True)[0][1]
    return hmac.new(
        get_settings().secret.encode(),
        b"wakemate:mcp-endpoint:v1:" + identity.encode(),
        hashlib.sha256,
    ).hexdigest()


def seal_config(endpoint: str, api_token: str, *, allow_loopback: bool = False) -> str:
    _validate_config_endpoint(endpoint, allow_loopback)
    payload = json.dumps({"endpoint": endpoint, "api_token": api_token})
    return _cipher().encrypt(payload.encode()).decode()


def open_config(encrypted_config: str, *, allow_loopback: bool = False) -> dict[str, str]:
    config = json.loads(_cipher().decrypt(encrypted_config.encode()))
    if (
        not isinstance(config, dict)
        or set(config) != {"endpoint", "api_token"}
        or not all(isinstance(v, str) and v for v in config.values())
    ):
        raise ValueError("Invalid MCP connection configuration")
    _validate_config_endpoint(config["endpoint"], allow_loopback)
    return config


async def lock_configurations(db):
    await db.execute(
        text("SELECT pg_advisory_xact_lock(:key)"), {"key": CONFIGURATION_LOCK}
    )


async def configure_connection(db, binding, endpoint, api_token):
    """Call only while holding the transaction configuration lock."""
    hashed_endpoint = endpoint_hash(endpoint)
    other = await db.scalar(
        select(MCPConnection.binding_id).where(
            MCPConnection.endpoint_hash == hashed_endpoint,
            MCPConnection.binding_id != binding.id,
        )
    )
    if other:
        raise HTTPException(409, "这个小智接入点已用于其他绑定，请使用该智能体对应的现有绑定")
    connection = await db.get(MCPConnection, binding.id)
    if connection is None:
        count = await db.scalar(select(func.count()).select_from(MCPConnection))
        if count >= MAX_CONNECTIONS:
            raise HTTPException(409, "最多可配置 16 个小智 MCP 接入点，请先断开不用的接入点")
        connection = MCPConnection(binding_id=binding.id, generation=1)
        db.add(connection)
    else:
        connection.generation += 1
    connection.encrypted_config = seal_config(endpoint, api_token)
    connection.endpoint_hash = hashed_endpoint
    connection.state = "queued"
    connection.updated_at = utcnow()
    connection.heartbeat = None
    connection.connected_at = None
    connection.last_error = None
    await db.flush()
    return connection


def connection_json(connection):
    if connection is None:
        return {
            "configured": False,
            "endpoint_host": None,
            "state": "not_configured",
            "heartbeat": None,
            "connected_at": None,
            "last_error": None,
        }
    state = connection.state
    if state == "queued" and (utcnow() - connection.updated_at).total_seconds() > 45:
        state = "offline"
    if state in {"connected", "connecting", "retrying"} and (
        connection.heartbeat is None
        or (utcnow() - connection.heartbeat).total_seconds() > 45
    ):
        state = "offline"
    return {
        "configured": True,
        "endpoint_host": "api.xiaozhi.me",
        "state": state,
        "heartbeat": connection.heartbeat,
        "connected_at": connection.connected_at,
        "last_error": connection.last_error,
    }
