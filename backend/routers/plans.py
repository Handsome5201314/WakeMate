"""
routers/plans.py — 用药计划 CRUD + 硬件同步触发
醒伴 WakeMate Backend
"""
import uuid
from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from db.database import get_db
from db.redis_client import enqueue_missed_check
from models.schemas import MessageOut, PlanCreate, PlanOut, PlanUpdate
from routers.deps import get_current_user_id

router = APIRouter()
logger = structlog.get_logger()


@router.get("", response_model=list[PlanOut], summary="获取用药计划列表")
async def list_plans(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        text("""
            SELECT id, drug_name, dosage, times, note, color, active, synced_to_hw, created_at
            FROM medication_plans
            WHERE user_id = :uid AND deleted_at IS NULL
            ORDER BY created_at ASC
        """),
        {"uid": user_id},
    )
    rows = result.fetchall()
    return [_row_to_plan(r) for r in rows]


@router.post("", response_model=PlanOut, status_code=status.HTTP_201_CREATED, summary="新增用药计划")
async def create_plan(
    body: PlanCreate,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    plan_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()
    sync_ver = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    times_str = "{" + ",".join(f'"{t}"' for t in body.times) + "}"

    await db.execute(
        text("""
            INSERT INTO medication_plans
              (id, user_id, drug_name, dosage, times, note, color,
               active, sync_version, synced_to_hw, created_at, updated_at)
            VALUES
              (:id, :uid, :drug, :dosage, :times::time[], :note, :color,
               true, :ver, false, :now, :now)
        """),
        {
            "id": plan_id, "uid": user_id, "drug": body.drug_name,
            "dosage": body.dosage, "times": times_str, "note": body.note,
            "color": body.color, "ver": sync_ver, "now": now,
        },
    )

    # 触发硬件同步（异步，不阻塞响应）
    import asyncio
    asyncio.create_task(_sync_plan_to_hw(user_id, db))

    logger.info("plan_created", plan_id=plan_id, drug=body.drug_name)
    return PlanOut(
        id=plan_id, drug_name=body.drug_name, dosage=body.dosage,
        times=body.times, note=body.note, color=body.color,
        active=True, synced_to_hw=False,
        created_at=datetime.now(timezone.utc),
    )


@router.put("/{plan_id}", response_model=PlanOut, summary="更新用药计划")
async def update_plan(
    plan_id: str,
    body: PlanUpdate,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.now(timezone.utc).isoformat()
    sync_ver = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    times_str = "{" + ",".join(f'"{t}"' for t in body.times) + "}"

    result = await db.execute(
        text("""
            UPDATE medication_plans
            SET drug_name=:drug, dosage=:dosage, times=:times::time[],
                note=:note, color=:color, active=:active,
                sync_version=:ver, synced_to_hw=false, updated_at=:now
            WHERE id=:pid AND user_id=:uid AND deleted_at IS NULL
            RETURNING id
        """),
        {
            "drug": body.drug_name, "dosage": body.dosage, "times": times_str,
            "note": body.note, "color": body.color,
            "active": body.active if body.active is not None else True,
            "ver": sync_ver, "now": now, "pid": plan_id, "uid": user_id,
        },
    )
    if not result.fetchone():
        raise HTTPException(status_code=404, detail="计划不存在")

    import asyncio
    asyncio.create_task(_sync_plan_to_hw(user_id, db))

    return PlanOut(
        id=plan_id, drug_name=body.drug_name, dosage=body.dosage,
        times=body.times, note=body.note, color=body.color,
        active=body.active if body.active is not None else True,
        synced_to_hw=False,
        created_at=datetime.now(timezone.utc),
    )


@router.delete("/{plan_id}", response_model=MessageOut, summary="删除用药计划（软删除）")
async def delete_plan(
    plan_id: str,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.now(timezone.utc).isoformat()
    result = await db.execute(
        text("""
            UPDATE medication_plans SET deleted_at=:now, updated_at=:now
            WHERE id=:pid AND user_id=:uid AND deleted_at IS NULL
            RETURNING id
        """),
        {"now": now, "pid": plan_id, "uid": user_id},
    )
    if not result.fetchone():
        raise HTTPException(status_code=404, detail="计划不存在")
    return MessageOut(message="计划已删除")


async def _sync_plan_to_hw(user_id: str, db: AsyncSession) -> None:
    """
    [架构约束] 用药计划变更后同步到 ESP32-S3 Flash。
    药盒本体不联网，计划固化本地 RTC，此处通过 xiaozhi-server 下发。
    """
    try:
        result = await db.execute(
            text("""
                SELECT d.id as device_id, d.device_sn
                FROM devices d
                WHERE d.user_id = :uid AND d.deleted_at IS NULL
                LIMIT 1
            """),
            {"uid": user_id},
        )
        device = result.fetchone()
        if not device:
            return

        plans_result = await db.execute(
            text("""
                SELECT drug_name, dosage, times::text[], id
                FROM medication_plans
                WHERE user_id = :uid AND active = true AND deleted_at IS NULL
            """),
            {"uid": user_id},
        )
        plans = [
            {"plan_id": str(r.id), "drug_name": r.drug_name,
             "dosage": r.dosage, "times": list(r.times), "active": True}
            for r in plans_result.fetchall()
        ]

        # 通过 xiaozhi-server 下发 PLAN_SYNC_DOWN 事件
        import json
        from services.xiaozhi_client import get_xiaozhi_client
        from core.config import get_settings
        settings = get_settings()

        if not settings.xiaozhi_mock_mode:
            client = get_xiaozhi_client()
            conn = await client.get_connection(user_id)
            await conn.send(json.dumps({
                "type": "PLAN_SYNC_DOWN",
                "device_id": str(device.device_id),
                "payload": {
                    "sync_version": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S"),
                    "plans": plans,
                    "server_ts": int(datetime.now(timezone.utc).timestamp() * 1000),
                },
            }))

        # 标记已同步
        await db.execute(
            text("UPDATE medication_plans SET synced_to_hw=true WHERE user_id=:uid"),
            {"uid": user_id},
        )
        await db.commit()
        logger.info("plan_synced_to_hw", user_id=user_id, plan_count=len(plans))

    except Exception as e:
        logger.error("plan_sync_failed", user_id=user_id, error=str(e))


def _row_to_plan(row) -> PlanOut:
    return PlanOut(
        id=str(row.id),
        drug_name=row.drug_name,
        dosage=row.dosage,
        times=list(row.times) if row.times else [],
        note=row.note,
        color=row.color or "#2C4A7E",
        active=row.active,
        synced_to_hw=row.synced_to_hw,
        created_at=row.created_at,
    )
