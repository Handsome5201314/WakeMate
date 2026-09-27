"""
routers/device.py — 硬件设备管理
设备注册 / 状态上报 / 心跳
醒伴 WakeMate Backend
"""
import uuid
from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from db.database import get_db
from db.redis_client import cache_device_state, enqueue_missed_check
from models.schemas import DeviceOut, DeviceRegister, DeviceStateUpdate, MessageOut
from routers.deps import get_current_user_id
from core.config import get_settings

router = APIRouter()
logger = structlog.get_logger()
settings = get_settings()


@router.post("/register", response_model=DeviceOut, summary="注册设备")
async def register_device(
    body: DeviceRegister,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    device_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    await db.execute(
        text("""
            INSERT INTO devices
              (id, user_id, device_sn, firmware_ver, bead_total, registered_at)
            VALUES (:id, :uid, :sn, :fw, :total, :now)
            ON CONFLICT (device_sn) DO UPDATE
              SET firmware_ver = :fw, bead_total = :total
        """),
        {
            "id": device_id, "uid": user_id, "sn": body.device_sn,
            "fw": body.firmware_ver, "total": body.bead_total, "now": now,
        },
    )

    # 初始化设备状态
    await db.execute(
        text("""
            INSERT INTO device_state (device_id, battery, bead_remain, updated_at)
            VALUES (:did, 100, :total, :now)
            ON CONFLICT (device_id) DO NOTHING
        """),
        {"did": device_id, "total": body.bead_total, "now": now},
    )

    logger.info("device_registered", device_id=device_id, sn=body.device_sn)
    return DeviceOut(
        id=device_id,
        device_sn=body.device_sn,
        device_type=body.device_type.value,
        firmware_ver=body.firmware_ver,
        bead_total=body.bead_total,
        last_sync_at=None,
    )


@router.get("", response_model=list[DeviceOut], summary="获取设备列表")
async def list_devices(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        text("""
            SELECT d.id, d.device_sn, d.firmware_ver, d.bead_total, d.last_sync_at,
                   ds.battery, ds.bead_remain, ds.rtc_drift_ms,
                   ds.watch_connected, ds.last_heartbeat
            FROM devices d
            LEFT JOIN device_state ds ON ds.device_id = d.id
            WHERE d.user_id = :uid AND d.deleted_at IS NULL
        """),
        {"uid": user_id},
    )
    rows = result.fetchall()
    return [
        DeviceOut(
            id=str(r.id),
            device_sn=r.device_sn,
            device_type="clasp_bead",
            firmware_ver=r.firmware_ver,
            bead_total=r.bead_total,
            last_sync_at=r.last_sync_at,
            state={
                "battery": r.battery,
                "bead_remain": r.bead_remain,
                "rtc_drift_ms": r.rtc_drift_ms,
                "watch_connected": r.watch_connected,
                "last_heartbeat": str(r.last_heartbeat) if r.last_heartbeat else None,
            },
        )
        for r in rows
    ]


@router.post("/{device_sn}/heartbeat", response_model=MessageOut, summary="设备心跳上报")
async def device_heartbeat(
    device_sn: str,
    body: DeviceStateUpdate,
    db: AsyncSession = Depends(get_db),
):
    """
    ESP32-S3 每 30s 调用此接口上报设备状态。
    同时返回服务器时间戳，用于 RTC 软校准。

    [架构约束] 药盒本体不联网，仅通过心跳同步状态和时间。
    """
    now = datetime.now(timezone.utc)
    server_ts = int(now.timestamp() * 1000)

    # 查找设备
    result = await db.execute(
        text("SELECT id FROM devices WHERE device_sn = :sn AND deleted_at IS NULL"),
        {"sn": device_sn},
    )
    row = result.fetchone()
    if not row:
        return MessageOut(message="设备未注册", data={"server_ts": server_ts})

    device_id = str(row.id)

    await db.execute(
        text("""
            UPDATE device_state
            SET battery=:bat, bead_remain=:remain,
                rtc_drift_ms=:drift, watch_connected=:watch,
                last_heartbeat=:now, updated_at=:now
            WHERE device_id=:did
        """),
        {
            "bat": body.battery, "remain": body.bead_remain,
            "drift": body.rtc_drift_ms, "watch": body.watch_connected,
            "now": now.isoformat(), "did": device_id,
        },
    )

    # Redis 热缓存
    await cache_device_state(device_id, {
        "battery": body.battery,
        "bead_remain": body.bead_remain,
        "watch_connected": body.watch_connected,
        "last_heartbeat": now.isoformat(),
        "toy_light": "pending",  # 默认待服药
    })

    # 低电量告警
    if body.battery <= 20:
        logger.warning("battery_low", device_sn=device_sn, battery=body.battery)

    return MessageOut(
        message="心跳已记录",
        data={"server_ts": server_ts},  # ESP32 用此值做 RTC 校准
    )


@router.post("/{device_sn}/event", response_model=MessageOut, summary="设备事件上报（开盖等）")
async def device_event(
    device_sn: str,
    body: dict,
    db: AsyncSession = Depends(get_db),
):
    """
    ESP32-S3 上报：BEAD_OPEN / REMINDER_TRIGGER / BATTERY_LOW 等事件。
    转发给 xiaozhi-server 事件总线。
    """
    event_type = body.get("type", "")
    logger.info("device_event_received", device_sn=device_sn, type=event_type)

    result = await db.execute(
        text("SELECT id, user_id FROM devices WHERE device_sn = :sn"),
        {"sn": device_sn},
    )
    dev = result.fetchone()
    if not dev:
        return MessageOut(message="设备未注册")

    user_id = str(dev.user_id)

    # 漏服计时器：提醒触发时启动
    if event_type == "REMINDER_TRIGGER":
        payload = body.get("payload", {})
        await enqueue_missed_check(
            reminder_key=payload.get("reminder_key", f"rem_{device_sn}_{int(datetime.now().timestamp())}"),
            plan_id=payload.get("plan_id", ""),
            drug_name=payload.get("drug_name", "用药"),
            user_id=user_id,
            timeout_seconds=settings.missed_dose_timeout_seconds,
        )

    return MessageOut(message="事件已接收", data={"server_ts": int(datetime.now(timezone.utc).timestamp() * 1000)})
