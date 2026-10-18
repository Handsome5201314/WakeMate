from __future__ import annotations

import uuid
from datetime import datetime, timezone


async def _provision(client, admin_headers, *, device_type="pillbox"):
    device_sn = "TEST-CLAIM-" + uuid.uuid4().hex
    response = await client.post(
        "/api/admin/devices",
        headers=admin_headers,
        json={
            "device_sn": device_sn,
            "device_type": device_type,
            "bead_total": 7,
            "firmware_ver": "dev-test",
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def _mcp_binding(client, admin_headers, patient_id, label):
    response = await client.post(
        "/api/admin/mcp-bindings",
        headers=admin_headers,
        json={"patient_id": patient_id, "label": label},
    )
    assert response.status_code == 201, response.text
    return response.json()["token"]


async def test_two_devices_claim_status_and_mcp_patient_isolation(
    client, actors, admin_headers
):
    patient = actors["patient"]
    other_patient = actors["other_patient"]
    first = await _provision(client, admin_headers)
    second = await _provision(client, admin_headers, device_type="clasp_bead")

    for device in (first, second):
        wrong = await client.post(
            "/api/device/bind",
            headers=patient["headers"],
            json={"device_sn": device["device_sn"], "claim_code": "wrong-claim-code"},
        )
        assert wrong.status_code == 403, wrong.text

        claimed = await client.post(
            "/api/device/bind",
            headers=patient["headers"],
            json={
                "device_sn": device["device_sn"],
                "claim_code": device["claim_code"],
            },
        )
        assert claimed.status_code == 200, claimed.text

        reused = await client.post(
            "/api/device/bind",
            headers=patient["headers"],
            json={
                "device_sn": device["device_sn"],
                "claim_code": device["claim_code"],
            },
        )
        assert reused.status_code == 403, reused.text

    app_devices = await client.get("/api/device", headers=patient["headers"])
    assert app_devices.status_code == 200, app_devices.text
    assert {item["device_sn"] for item in app_devices.json()} == {
        first["device_sn"],
        second["device_sn"],
    }
    other_app = await client.get("/api/device", headers=other_patient["headers"])
    assert other_app.status_code == 200, other_app.text
    assert other_app.json() == []

    patient_token = await _mcp_binding(
        client, admin_headers, patient["id"], "device-claim-test-patient"
    )
    patient_mcp = await client.post(
        "/api/mcp/tools/get_device_status",
        headers={"Authorization": f"Bearer {patient_token}"},
        json={},
    )
    assert patient_mcp.status_code == 200, patient_mcp.text
    assert {item["device_sn"] for item in patient_mcp.json()["devices"]} == {
        first["device_sn"],
        second["device_sn"],
    }

    other_token = await _mcp_binding(
        client, admin_headers, other_patient["id"], "device-claim-test-other"
    )
    other_mcp = await client.post(
        "/api/mcp/tools/get_device_status",
        headers={"Authorization": f"Bearer {other_token}"},
        json={},
    )
    assert other_mcp.status_code == 200, other_mcp.text
    assert other_mcp.json()["devices"] == []


async def test_heartbeat_changes_online_state_without_confirming_dose(
    client, actors, admin_headers
):
    patient = actors["patient"]
    plan = await client.post(
        "/api/plans",
        headers=patient["headers"],
        json={"drug_name": "Test medication", "dosage": "1 tablet", "times": ["00:00"]},
    )
    assert plan.status_code == 201, plan.text
    doses_before = await client.get("/api/doses", headers=patient["headers"])
    assert doses_before.status_code == 200, doses_before.text
    assert len(doses_before.json()) == 1
    dose_id = doses_before.json()[0]["id"]
    assert doses_before.json()[0]["status"] == "pending"

    device = await _provision(client, admin_headers)
    claimed = await client.post(
        "/api/device/bind",
        headers=patient["headers"],
        json={"device_sn": device["device_sn"], "claim_code": device["claim_code"]},
    )
    assert claimed.status_code == 200, claimed.text

    before = await client.get("/api/device", headers=patient["headers"])
    assert before.status_code == 200, before.text
    before_device = next(
        item for item in before.json() if item["device_sn"] == device["device_sn"]
    )
    assert before_device["state"]["status"] == "offline"

    heartbeat = await client.post(
        "/api/device/events",
        headers={"Authorization": f"Bearer {device['device_token']}"},
        json={
            "event_id": uuid.uuid4().hex,
            "kind": "heartbeat",
            "occurred_at": datetime.now(timezone.utc).isoformat(),
            "battery": 88,
            "bead_remain": 6,
        },
    )
    assert heartbeat.status_code == 200, heartbeat.text
    assert heartbeat.json()["duplicate"] is False
    assert heartbeat.json()["dose_confirmed"] is False

    after = await client.get("/api/device", headers=patient["headers"])
    assert after.status_code == 200, after.text
    after_device = next(
        item for item in after.json() if item["device_sn"] == device["device_sn"]
    )
    assert after_device["state"]["status"] == "online"
    assert after_device["state"]["battery"] == 88
    assert after_device["state"]["bead_remain"] == 6

    doses_after = await client.get("/api/doses", headers=patient["headers"])
    assert doses_after.status_code == 200, doses_after.text
    current_dose = next(item for item in doses_after.json() if item["id"] == dose_id)
    assert current_dose["status"] == "pending"
    assert current_dose["actual_time"] is None
    assert current_dose["evidence_count"] == 0
    records = await client.get("/api/records", headers=patient["headers"])
    assert records.status_code == 200, records.text
    assert records.json() == []

    mcp_token = await _mcp_binding(
        client, admin_headers, patient["id"], "device-claim-test-heartbeat"
    )
    mcp = await client.post(
        "/api/mcp/tools/get_device_status",
        headers={"Authorization": f"Bearer {mcp_token}"},
        json={},
    )
    assert mcp.status_code == 200, mcp.text
    mcp_device = mcp.json()["devices"][0]
    assert mcp_device["state"]["status"] == "online"
    assert mcp_device["state"]["battery"] == 88
    assert mcp_device["state"]["bead_remain"] == 6
