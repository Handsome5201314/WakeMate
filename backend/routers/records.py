"""
routers/records.py — 服药记录 + 统计聚合
醒伴 WakeMate Backend
"""
from datetime import datetime, timezone, timedelta

import structlog
from fastapi import APIRouter, Depends, Query
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from db.database import get_db
from db.redis_client import cancel_missed_check, enqueue_missed_check
from models.schemas import DailyStatsOut, DoseConfirmRequest, DoseRecordOut, MessageOut
from routers.deps import get_current_user_id
from services.mcp_executor import execute_mcp_calls

router = APIRouter()
logger = structlog.get_logger()


@router.post("/confirm", response_model=MessageOut, summary="确认已服药")
async def confirm_dose(
    body: DoseConfirmRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    用户点击「已服用」后调用此接口。
    - 归档服药记录（result=ontime/late）
    - 取消漏服计时器
    - 触发家属推送
    """
    from core.config import get_settings
    settings = get_settings()

    now = datetime.now(timezone.utc)
    delay = None
    result_val = "ontime"

    try:
        diff = int((now - body.scheduled_time.replace(tzinfo=timezone.utc)).total_seconds())
        delay = diff
        result_val = "ontime" if diff <= 1800 else "late"
    except Exception:
        pass

    # 取消漏服计时器
    await cancel_missed_check(body.reminder_id)

    # 调用 MCP 归档 + 推送
    await execute_mcp_calls(
        [
            {
                "tool": "wakemate.archiveRecord",
                "params": {
                    "reminder_id": body.reminder_id,
                    "plan_id": str(body.plan_id),
                    "drug_name": body.drug_name,
                    "dosage": "",
                    "scheduled_time": body.scheduled_time.isoformat(),
                    "actual_time": now.isoformat(),
                    "result": result_val,
                    "confirmed_by": body.confirmed_by.value,
                    "delay_seconds": delay,
                },
            },
            {
                "tool": "wakemate.pushFamily",
                "params": {
                    "event_type": "dose_confirmed",
                    "body": f"{body.drug_name} 已按时服用 ✓（{now.strftime('%H:%M')}）",
                    "check_quiet_hours": True,
                    "priority": "normal",
                    "data": {"drug_name": body.drug_name, "result": result_val},
                },
            },
        ],
        user_id,
        db,
    )

    logger.info("dose_confirmed", user_id=user_id, result=result_val, drug=body.drug_name)
    return MessageOut(message=f"服药记录已确认，结果：{result_val}")


@router.get("", response_model=list[DoseRecordOut], summary="获取服药记录列表")
async def list_records(
    days: int = Query(default=7, ge=1, le=90),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    result = await db.execute(
        text("""
            SELECT id, drug_name, dosage, scheduled_time, actual_time,
                   result, confirmed_by, delay_seconds, created_at
            FROM dose_records
            WHERE user_id = :uid AND scheduled_time >= :since
            ORDER BY scheduled_time DESC
        """),
        {"uid": user_id, "since": since},
    )
    rows = result.fetchall()
    return [
        DoseRecordOut(
            id=str(r.id), drug_name=r.drug_name, dosage=r.dosage,
            scheduled_time=r.scheduled_time, actual_time=r.actual_time,
            result=r.result, confirmed_by=r.confirmed_by,
            delay_seconds=r.delay_seconds, created_at=r.created_at,
        )
        for r in rows
    ]


@router.get("/stats", response_model=list[DailyStatsOut], summary="每日统计（按时率/连续天数）")
async def get_stats(
    days: int = Query(default=30, ge=7, le=365),
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    返回最近 N 天的每日统计，用于 ECharts 图表渲染。
    包含今日按时率、连续打卡天数（MVP 红线指标可视化）。
    """
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    result = await db.execute(
        text("""
            SELECT
                DATE(scheduled_time AT TIME ZONE 'Asia/Shanghai') AS stat_date,
                COUNT(*) AS total,
                COUNT(*) FILTER (WHERE result='ontime') AS ontime,
                COUNT(*) FILTER (WHERE result='late')   AS late,
                COUNT(*) FILTER (WHERE result='missed') AS missed
            FROM dose_records
            WHERE user_id = :uid AND scheduled_time >= :since
            GROUP BY stat_date
            ORDER BY stat_date ASC
        """),
        {"uid": user_id, "since": since},
    )
    rows = result.fetchall()

    # 计算连续打卡天数
    streak = _calc_streak(rows)

    return [
        DailyStatsOut(
            date=str(r.stat_date),
            total=r.total,
            ontime=r.ontime,
            late=r.late,
            missed=r.missed,
            rate=round(r.ontime / r.total * 100, 1) if r.total else 0.0,
            streak_days=streak,
        )
        for r in rows
    ]


def _calc_streak(rows) -> int:
    """从最新记录往前数连续有按时服药的天数"""
    if not rows:
        return 0
    streak = 0
    from datetime import date
    today = date.today()
    prev = today

    for row in reversed(rows):
        d = row.stat_date if hasattr(row.stat_date, "year") else datetime.strptime(str(row.stat_date), "%Y-%m-%d").date()
        if (prev - d).days > 1:
            break
        if row.ontime > 0:
            streak += 1
            prev = d
        else:
            break
    return streak
