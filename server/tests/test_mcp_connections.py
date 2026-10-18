"""Verify browser-managed XiaoZhi connections against isolated PostgreSQL."""

import asyncio
import json
from datetime import timedelta

import pytest
from fastapi import HTTPException
from sqlalchemy import func, select

from app.mcp_connections import (
    endpoint_hash,
    open_config,
    seal_config,
    validate_endpoint,
)
from app.models import Audit, Binding, MCPConnection, User, utcnow
from app.security import digest

ENDPOINT = "wss://api.xiaozhi.me/mcp/?token=test-only-xiaozhi-credential"


async def create_binding(client, admin_headers, patient_id, endpoint=ENDPOINT):
    body = {"patient_id": patient_id, "label": "小智测试绑定"}
    if endpoint is not None:
        body["endpoint"] = endpoint
    return await client.post(
        "/api/admin/mcp-bindings", headers=admin_headers, json=body
    )


@pytest.mark.parametrize(
    "endpoint",
    [
        "ws://api.xiaozhi.me/mcp/?token=secret",
        "https://api.xiaozhi.me/mcp/?token=secret",
        "wss://localhost/mcp/?token=secret",
        "wss://127.0.0.1/mcp/?token=secret",
        "wss://[::1]/mcp/?token=secret",
        "wss://169.254.169.254/mcp/?token=secret",
        "wss://api.xiaozhi.me.evil.test/mcp/?token=secret",
        "wss://api.xiaozhi.me./mcp/?token=secret",
        "wss://secret@api.xiaozhi.me/mcp/?token=secret",
        "wss://api.xiaozhi.me@evil.test/mcp/?token=secret",
        "wss://api.xiaozhi.me:8443/mcp/?token=secret",
        "wss://api.xiaozhi.me:/mcp/?token=secret",
        "wss://api.xiaozhi.me/other/?token=secret",
        "wss://api.xiaozhi.me/mcp/?token=secret#fragment",
        "wss://api.xiaozhi.me/mcp/?token=secret#",
        "wss://api.xiaozhi.me/mcp/?token=secret&token=other",
        "wss://api.xiaozhi.me/mcp/?token=secret&extra=true",
        "wss://api.xiaozhi.me/mcp/?Token=secret",
        "wss://api.xiaozhi.me/mcp/?token=",
        "wss://api.xiaozhi.me/mcp/?token=%20",
        "wss://api.xiaozhi.me/mcp/?token=secret%0a",
        "wss://api.xiaozhi.me/mcp/?token=sec\nret",
        "wss://api.xiaozhi.me/mcp/",
        "",
    ],
)
def test_only_official_credential_endpoint_is_allowed(endpoint):
    with pytest.raises(HTTPException) as caught:
        validate_endpoint(endpoint)
    assert caught.value.status_code == 422
    assert "secret" not in caught.value.detail


def test_endpoint_variants_cannot_bypass_identity_and_test_transport_is_explicit():
    assert validate_endpoint(ENDPOINT) == ENDPOINT
    variant = "wss://API.XIAOZHI.ME:443/mcp?token=test-only-xiaozhi-%63redential"
    assert endpoint_hash(ENDPOINT) == endpoint_hash(variant)
    assert endpoint_hash(ENDPOINT) != endpoint_hash(ENDPOINT + "-different")
    loopback = "ws://127.0.0.1:50000/mcp"
    with pytest.raises(HTTPException):
        seal_config(loopback, "test-only")
    encrypted = seal_config(loopback, "test-only", allow_loopback=True)
    with pytest.raises(HTTPException):
        open_config(encrypted)
    assert open_config(encrypted, allow_loopback=True)["endpoint"] == loopback


async def test_create_encrypts_credentials_and_never_returns_endpoint(
    client, actors, admin_headers, database
):
    response = await create_binding(client, admin_headers, actors["patient"]["id"])
    assert response.status_code == 201, response.text
    binding = response.json()
    assert "test-only-xiaozhi-credential" not in response.text
    assert binding["connection"] == {
        "configured": True,
        "endpoint_host": "api.xiaozhi.me",
        "state": "queued",
        "heartbeat": None,
        "connected_at": None,
        "last_error": None,
    }
    async with database() as db:
        stored_binding = await db.get(Binding, binding["id"])
        connection = await db.get(MCPConnection, binding["id"])
        assert stored_binding.token_hash == digest(binding["token"])
        assert ENDPOINT not in connection.encrypted_config
        assert binding["token"] not in connection.encrypted_config
        assert "test-only-xiaozhi-credential" not in connection.endpoint_hash
        assert open_config(connection.encrypted_config) == {
            "endpoint": ENDPOINT,
            "api_token": binding["token"],
        }
        assert connection.generation == 1
        audit = (await db.scalars(select(Audit))).all()
        assert ENDPOINT not in json.dumps([entry.detail for entry in audit])
        assert binding["token"] not in json.dumps([entry.detail for entry in audit])
    listed = await client.get("/api/admin/mcp-bindings", headers=admin_headers)
    assert listed.status_code == 200
    assert listed.json()[0]["connection"]["configured"]
    assert binding["token"] not in listed.text
    assert "test-only-xiaozhi-credential" not in listed.text
    usable = await client.post(
        "/api/mcp/tools/get_today_doses",
        headers={"Authorization": "Bearer " + binding["token"]},
        json={},
    )
    assert usable.status_code == 200, usable.text


async def test_update_rotates_api_token_and_disconnect_revokes_inflight_calls(
    client, actors, admin_headers, database
):
    created = await create_binding(
        client, admin_headers, actors["patient"]["id"], endpoint=None
    )
    assert created.status_code == 201
    binding = created.json()
    assert binding["connection"]["state"] == "not_configured"
    url = f"/api/admin/mcp-bindings/{binding['id']}/connection"
    first = await client.put(url, headers=admin_headers, json={"endpoint": ENDPOINT})
    assert first.status_code == 200, first.text
    assert "token" not in first.json()
    async with database() as db:
        connection = await db.get(MCPConnection, binding["id"])
        first_config = open_config(connection.encrypted_config)
        first_ciphertext = connection.encrypted_config
        assert first_config["api_token"] != binding["token"]
        assert connection.generation == 1
        connection.state = "connected"
        connection.heartbeat = utcnow()
        connection.connected_at = utcnow()
        await db.commit()
    updated = await client.put(
        url, headers=admin_headers, json={"endpoint": ENDPOINT + "-updated"}
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["connection"]["state"] == "queued"
    assert updated.json()["connection"]["connected_at"] is None
    assert updated.json()["connection"]["heartbeat"] is None
    async with database() as db:
        connection = await db.get(MCPConnection, binding["id"])
        next_config = open_config(connection.encrypted_config)
        assert connection.generation == 2
        assert connection.encrypted_config != first_ciphertext
        assert next_config["api_token"] != first_config["api_token"]
        stored_binding = await db.get(Binding, binding["id"])
        assert stored_binding.token_hash == digest(next_config["api_token"])
    for token in (binding["token"], first_config["api_token"]):
        response = await client.post(
            "/api/mcp/tools/get_today_doses",
            headers={"Authorization": "Bearer " + token}, json={},
        )
        assert response.status_code == 401
    disconnected = await client.delete(url, headers=admin_headers)
    assert disconnected.status_code == 200
    assert not disconnected.json()["connection"]["configured"]
    async with database() as db:
        assert await db.get(MCPConnection, binding["id"]) is None
        assert (await db.get(Binding, binding["id"])).active
    response = await client.post(
        "/api/mcp/tools/get_today_doses",
        headers={"Authorization": "Bearer " + next_config["api_token"]}, json={},
    )
    assert response.status_code == 401


async def test_connection_permissions_patient_identity_validation_and_revocation(
    client, actors, admin_headers, database
):
    body = {
        "patient_id": actors["patient"]["id"],
        "label": "Protected binding", "endpoint": ENDPOINT,
    }
    for headers, expected in (({}, 401), (actors["patient"]["headers"], 403)):
        response = await client.post("/api/admin/mcp-bindings", headers=headers, json=body)
        assert response.status_code == expected
        response = await client.get("/api/admin/mcp-bindings", headers=headers)
        assert response.status_code == expected
    response = await create_binding(client, admin_headers, actors["caregiver"]["id"])
    assert response.status_code == 404
    created = await create_binding(client, admin_headers, actors["patient"]["id"])
    assert created.status_code == 201
    binding = created.json()
    url = f"/api/admin/mcp-bindings/{binding['id']}/connection"
    for headers, expected in (({}, 401), (actors["caregiver"]["headers"], 403)):
        response = await client.put(url, headers=headers, json={"endpoint": ENDPOINT})
        assert response.status_code == expected
        response = await client.delete(url, headers=headers)
        assert response.status_code == expected
        response = await client.post(
            f"/api/admin/mcp-bindings/{binding['id']}/revoke", headers=headers
        )
        assert response.status_code == expected
    invalid = await client.put(
        url, headers=admin_headers,
        json={"endpoint": "wss://localhost/?token=private-value-never-echo"},
    )
    assert invalid.status_code == 422
    assert "private-value-never-echo" not in invalid.text
    async with database() as db:
        patient = await db.get(User, actors["patient"]["id"])
        patient.active = False
        await db.commit()
    response = await client.put(url, headers=admin_headers, json={"endpoint": ENDPOINT})
    assert response.status_code == 409
    revoked = await client.post(
        f"/api/admin/mcp-bindings/{binding['id']}/revoke", headers=admin_headers
    )
    assert revoked.status_code == 200
    assert not revoked.json()["active"]
    assert not revoked.json()["connection"]["configured"]
    async with database() as db:
        assert await db.get(MCPConnection, binding["id"]) is None
    response = await client.put(url, headers=admin_headers, json={"endpoint": ENDPOINT})
    assert response.status_code == 409


async def test_stale_connection_heartbeat_is_not_reported_as_connected(
    client, actors, admin_headers, database
):
    created = await create_binding(client, admin_headers, actors["patient"]["id"])
    binding_id = created.json()["id"]
    async with database() as db:
        connection = await db.get(MCPConnection, binding_id)
        connection.state = "connected"
        connection.heartbeat = utcnow() - timedelta(seconds=46)
        await db.commit()
    listed = await client.get("/api/admin/mcp-bindings", headers=admin_headers)
    assert listed.json()[0]["connection"]["state"] == "offline"
    async with database() as db:
        connection = await db.get(MCPConnection, binding_id)
        connection.heartbeat = utcnow()
        await db.commit()
    listed = await client.get("/api/admin/mcp-bindings", headers=admin_headers)
    assert listed.json()[0]["connection"]["state"] == "connected"
    async with database() as db:
        connection = await db.get(MCPConnection, binding_id)
        connection.state = "queued"
        connection.heartbeat = None
        connection.updated_at = utcnow() - timedelta(seconds=46)
        await db.commit()
    listed = await client.get("/api/admin/mcp-bindings", headers=admin_headers)
    assert listed.json()[0]["connection"]["state"] == "offline"


async def test_one_endpoint_cannot_bind_two_patient_identities(
    client, actors, admin_headers, database
):
    first = await create_binding(client, admin_headers, actors["patient"]["id"])
    assert first.status_code == 201
    # Equivalent URL spellings still identify the same XiaoZhi access token.
    equivalent = "wss://API.XIAOZHI.ME:443/mcp?token=test-only-xiaozhi-%63redential"
    duplicate = await create_binding(
        client, admin_headers, actors["other_patient"]["id"], endpoint=equivalent
    )
    assert duplicate.status_code == 409
    assert "test-only-xiaozhi-" not in duplicate.text
    async with database() as db:
        assert await db.scalar(select(func.count()).select_from(Binding)) == 1
        assert await db.scalar(select(func.count()).select_from(MCPConnection)) == 1
    disconnected = await client.delete(
        f"/api/admin/mcp-bindings/{first.json()['id']}/connection", headers=admin_headers
    )
    assert disconnected.status_code == 200
    second = await create_binding(
        client, admin_headers, actors["other_patient"]["id"], endpoint=equivalent
    )
    assert second.status_code == 201, second.text


async def test_concurrent_configuration_enforces_capacity_without_partial_bindings(
    client, actors, admin_headers, database
):
    async with database() as db:
        for index in range(15):
            token, endpoint = f"test-api-{index}", ENDPOINT + f"-{index}"
            binding = Binding(
                patient_id=actors["patient"]["id"], label=f"Capacity {index}",
                token_hash=digest(token),
            )
            db.add(binding)
            await db.flush()
            db.add(MCPConnection(
                binding_id=binding.id,
                encrypted_config=seal_config(endpoint, token),
                endpoint_hash=endpoint_hash(endpoint),
            ))
        await db.commit()
    responses = await asyncio.gather(*[
        create_binding(
            client, admin_headers, actors["patient"]["id"], endpoint=ENDPOINT + suffix
        ) for suffix in ("-competing-a", "-competing-b")
    ])
    assert sorted(response.status_code for response in responses) == [201, 409]
    async with database() as db:
        assert await db.scalar(select(func.count()).select_from(MCPConnection)) == 16
        assert await db.scalar(select(func.count()).select_from(Binding)) == 16
