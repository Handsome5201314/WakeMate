"""
routers/settings.py — 用户设置 CRUD
醒伴 WakeMate Backend

GET  /api/settings            获取当前用户设置
PUT  /api/settings            更新推送/静默设置
PUT  /api/settings/profile    更新显示名 / 时区
"""
from datetime import datetime, timezone

import structlog
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from db.database import get_db
from models.schemas import MessageOut, UserSettingsOut, UserSettingsUpdate
from routers.deps import get_current_user_id

router = APIRouter()
logger = structlog.get_logger()


@router.get("", response_model=UserSettingsOut, summary="获取用户设置")
async def get_settings(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        text("""
            SELECT family_push_enabled, quiet_start, quiet_end,
                   daily_push_limit, snooze_minutes, max_snooze_count
            FROM user_settings WHERE user_id = :uid
        """),
        {"uid": user_id},
    )
    row = result.fetchone()

    if not row:
        # 初始化默认设置
        await db.execute(
            text("INSERT INTO user_settings (user_id) VALUES (:uid) ON CONFLICT DO NOTHING"),
            {"uid": user_id},
        )
        return UserSettingsOut(
            family_push_enabled=True,
            quiet_start="22:00",
            quiet_end="07:00",
            daily_push_limit=5,
            snooze_minutes=15,
            max_snooze_count=2,
        )

    return UserSettingsOut(
        family_push_enabled=row.family_push_enabled,
        quiet_start=str(row.quiet_start)[:5],
        quiet_end=str(row.quiet_end)[:5],
        daily_push_limit=row.daily_push_limit,
        snooze_minutes=row.snooze_minutes,
        max_snooze_count=row.max_snooze_count,
    )


@router.put("", response_model=MessageOut, summary="更新推送与提醒设置")
async def update_settings(
    body: UserSettingsUpdate,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    [MVP 约束] 家属推送打扰感目标 ≤3/5
    quiet_start/quiet_end 控制静默时段，超出此段的推送将延后至 quiet_end 发送
    """
    updates = []
    params: dict = {"uid": user_id, "now": datetime.now(timezone.utc).isoformat()}

    if body.family_push_enabled is not None:
        updates.append("family_push_enabled = :push")
        params["push"] = body.family_push_enabled

    if body.quiet_start is not None:
        updates.append("quiet_start = :qs::time")
        params["qs"] = body.quiet_start

    if body.quiet_end is not None:
        updates.append("quiet_end = :qe::time")
        params["qe"] = body.quiet_end

    if body.daily_push_limit is not None:
        updates.append("daily_push_limit = :limit")
        params["limit"] = body.daily_push_limit

    if body.snooze_minutes is not None:
        updates.append("snooze_minutes = :snooze")
        params["snooze"] = body.snooze_minutes

    if not updates:
        return MessageOut(message="无更新内容")

    updates.append("updated_at = :now")
    sql = f"UPDATE user_settings SET {', '.join(updates)} WHERE user_id = :uid"
    await db.execute(text(sql), params)

    logger.info("settings_updated", user_id=user_id, fields=list(params.keys()))
    return MessageOut(message="设置已更新")


@router.put("/profile", response_model=MessageOut, summary="更新个人信息")
async def update_profile(
    body: dict,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    display_name = body.get("display_name", "").strip()
    timezone_str = body.get("timezone", "Asia/Shanghai")

    if display_name:
        await db.execute(
            text("""
                UPDATE users SET display_name = :name, timezone = :tz, updated_at = :now
                WHERE id = :uid
            """),
            {"name": display_name, "tz": timezone_str,
             "now": datetime.now(timezone.utc).isoformat(), "uid": user_id},
        )

    return MessageOut(message="个人信息已更新")


@router.get("/caregiver", summary="获取家属绑定信息")
async def get_caregiver(
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        text("SELECT id, display_name, phone FROM users WHERE patient_id = :uid AND role='caregiver'"),
        {"uid": user_id},
    )
    caregivers = [
        {"id": str(r.id), "name": r.display_name, "phone": r.phone or ""}
        for r in result.fetchall()
    ]
    return {"caregivers": caregivers}
