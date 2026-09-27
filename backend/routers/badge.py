"""
routers/badge.py — 胸牌/桌面摆件数据端点
GET /badge/{device_token} — 无需 JWT，供 ESP32 直接轮询
醒伴 WakeMate Backend
"""
from datetime import datetime, timezone, timedelta

import structlog
from fastapi import APIRouter, HTTPException
from sqlalchemy import text

from db.database import AsyncSessionLocal
from db.redis_client import get_device_state
from models.schemas import BadgeDataOut

router = APIRouter()
logger = structlog.get_logger()


@router.get("/badge/{device_token}", response_model=BadgeDataOut, summary="胸牌/摆件数据（无鉴权）")
async def get_badge_data(device_token: str):
    """
    供 ESP32 电子胸牌 / 桌面摆件每 60s 轮询。
    device_token = device_sn 或预生成的访问 token（轻量鉴权）。

    返回数据包含：
    - 今日按时率 / 连续打卡天数 / 下次服药信息
    - 小醒当前姿态（摆件据此切换头像动画）
    - 急救基本信息（断网时摆件 Flash 缓存）
    """
    async with AsyncSessionLocal() as db:
        # 通过 device_sn 查找用户
        result = await db.execute(
            text("""
                SELECT d.user_id, d.id as device_id, u.display_name
                FROM devices d
                JOIN users u ON u.id = d.user_id
                WHERE d.device_sn = :sn AND d.deleted_at IS NULL
            """),
            {"sn": device_token},
        )
        row = result.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="设备未注册")

        user_id = str(row.user_id)
        user_name = row.display_name

        # 今日统计
        today = datetime.now(timezone.utc).date().isoformat()
        stats_result = await db.execute(
            text("""
                SELECT COUNT(*) AS total,
                       COUNT(*) FILTER (WHERE result='ontime') AS ontime
                FROM dose_records
                WHERE user_id = :uid
                  AND scheduled_time::date = :today
            """),
            {"uid": user_id, "today": today},
        )
        stats = stats_result.fetchone()
        total = stats.total or 1
        ontime = stats.ontime or 0
        today_rate = round(ontime / total * 100, 1)

        # 连续打卡天数
        streak_result = await db.execute(
            text("""
                SELECT COUNT(DISTINCT DATE(scheduled_time AT TIME ZONE 'Asia/Shanghai')) AS days
                FROM dose_records
                WHERE user_id = :uid
                  AND result = 'ontime'
                  AND scheduled_time >= NOW() - INTERVAL '30 days'
            """),
            {"uid": user_id},
        )
        streak = streak_result.scalar() or 0

        # 下次服药
        now_time = datetime.now(timezone.utc).strftime("%H:%M")
        plans_result = await db.execute(
            text("""
                SELECT drug_name, dosage, times
                FROM medication_plans
                WHERE user_id = :uid AND active = true AND deleted_at IS NULL
                ORDER BY created_at ASC
            """),
            {"uid": user_id},
        )
        plans = plans_result.fetchall()

        next_time, next_drug = _get_next_dose(plans)

        # 药物摘要（急救用）
        med_summary = " · ".join(
            f"{p.drug_name} {p.dosage}" for p in plans if p
        )[:100]

        # 设备状态 → 决定小醒姿态和灯光
        device_state = await get_device_state(str(row.device_id)) or {}
        toy_light = device_state.get("toy_light", "pending")
        pose_map = {"pending": "gentle", "done": "calm", "missed": "soothe"}
        pose = pose_map.get(toy_light, "gentle")

        # 急救联系人（取家属账号）
        caregiver_result = await db.execute(
            text("""
                SELECT display_name, phone FROM users
                WHERE patient_id = :uid AND role = 'caregiver'
                LIMIT 1
            """),
            {"uid": user_id},
        )
        caregiver = caregiver_result.fetchone()
        emergency_name = caregiver.display_name if caregiver else "家属"
        emergency_phone = caregiver.phone if caregiver else "请扫码查看"

        return BadgeDataOut(
            user_name=user_name,
            today_rate=today_rate,
            streak_days=int(streak),
            next_dose_time=next_time,
            next_drug_name=next_drug,
            toy_light=toy_light,
            xiaoxing_pose=pose,
            emergency_name=emergency_name,
            emergency_phone=emergency_phone or "",
            medication_summary=med_summary,
        )


def _get_next_dose(plans) -> tuple:
    """从计划列表中找最近的下一次服药时间"""
    from datetime import time as dtime
    now = datetime.now(timezone.utc)
    now_mins = now.hour * 60 + now.minute
    best_diff = float("inf")
    best_time = best_drug = None

    for p in plans:
        if not p.times:
            continue
        for t in p.times:
            try:
                hh, mm = str(t)[:5].split(":")
                mins = int(hh) * 60 + int(mm)
                diff = mins - now_mins
                if diff < 0:
                    diff += 24 * 60
                if diff < best_diff:
                    best_diff = diff
                    best_time = f"{hh}:{mm}"
                    best_drug = p.drug_name
            except Exception:
                pass
    return best_time, best_drug


# ── 急救公开页 ───────────────────────────────────────────────
@router.get("/emergency/{token}", summary="急救信息（无鉴权，QR码扫描）")
async def get_emergency_info(token: str):
    """
    QR 码扫描后访问此端点，无需登录。
    返回：用药清单 + 急救联系人 + 用药禁忌。
    token = user_id 的 base64 编码（或短码）。
    """
    import base64
    try:
        user_id = base64.urlsafe_b64decode(token + "==").decode()
    except Exception:
        user_id = token  # 直接当 user_id 用（演示模式）

    async with AsyncSessionLocal() as db:
        user_result = await db.execute(
            text("SELECT display_name FROM users WHERE id = :uid"),
            {"uid": user_id},
        )
        user = user_result.fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="用户不存在")

        plans_result = await db.execute(
            text("""
                SELECT drug_name, dosage, times::text[], note
                FROM medication_plans
                WHERE user_id = :uid AND active = true AND deleted_at IS NULL
            """),
            {"uid": user_id},
        )
        plans = [
            {
                "drug_name": p.drug_name,
                "dosage": p.dosage,
                "times": list(p.times) if p.times else [],
                "note": p.note or "",
            }
            for p in plans_result.fetchall()
        ]

        caregiver_result = await db.execute(
            text("""
                SELECT display_name, phone FROM users
                WHERE patient_id = :uid AND role = 'caregiver'
            """),
            {"uid": user_id},
        )
        contacts = [
            {"name": r.display_name, "phone": r.phone, "relation": "家属"}
            for r in caregiver_result.fetchall()
        ]

        return {
            "user_name": user.display_name,
            "emergency_contacts": contacts,
            "current_medications": plans,
            "medication_warnings": [
                "服药期间请勿饮酒",
                "请勿自行调整剂量",
                "如有不适请立即就医",
            ],
            "last_updated": datetime.now(timezone.utc).isoformat(),
            "_note": "此页面由醒伴 WakeMate 提供 · 醒时科技 Wakeshift",
        }
