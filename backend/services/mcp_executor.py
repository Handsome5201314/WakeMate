"""
services/mcp_executor.py — MCP 工具调用解析与执行
醒伴 WakeMate Backend

小醒 Agent 输出 ---MCP_CALL--- 块后，由本模块：
  1. 解析 JSON 工具调用列表
  2. 依次执行：archiveRecord / pushFamily / vibrate
  3. 返回执行结果供 Agent 继续推理

[MVP 风险] 头号风险：推送通道稳定性。pushFamily 有三重保险兜底。
"""
import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any

import structlog
from sqlalchemy.ext.asyncio import AsyncSession

from core.config import get_settings
from db.redis_client import cancel_missed_check, enqueue_missed_check

settings = get_settings()
logger = structlog.get_logger()

# MCP_CALL 块正则
_MCP_PATTERN = re.compile(
    r"---MCP_CALL---\s*(.*?)\s*---MCP_END---",
    re.DOTALL,
)


def extract_mcp_calls(text: str) -> list[dict]:
    """从 Agent 输出文本中提取 MCP 工具调用列表"""
    match = _MCP_PATTERN.search(text)
    if not match:
        return []
    try:
        data = json.loads(match.group(1))
        return data.get("calls", [])
    except json.JSONDecodeError as e:
        logger.warning("mcp_parse_error", error=str(e), raw=match.group(1)[:200])
        return []


async def execute_mcp_calls(
    calls: list[dict],
    user_id: str,
    db: AsyncSession,
) -> list[dict]:
    """执行工具调用列表，返回每个工具的执行结果"""
    results = []
    for call in calls:
        tool = call.get("tool", "")
        params = call.get("params", {})
        result = await _dispatch(tool, params, user_id, db)
        results.append({"tool": tool, "result": result})
    return results


async def _dispatch(tool: str, params: dict, user_id: str, db: AsyncSession) -> dict:
    handlers = {
        "wakemate.archiveRecord":  _archive_record,
        "wakemate.pushFamily":     _push_family,
        "wakemate.vibrate":        _vibrate,
        "wakemate.checkQuietHours": _check_quiet_hours,
    }
    handler = handlers.get(tool)
    if not handler:
        logger.warning("unknown_mcp_tool", tool=tool)
        return {"success": False, "error": f"Unknown tool: {tool}"}
    try:
        return await handler(params, user_id, db)
    except Exception as e:
        logger.error("mcp_tool_error", tool=tool, error=str(e))
        return {"success": False, "error": str(e)}


# ── wakemate.archiveRecord ────────────────────────────────────
async def _archive_record(params: dict, user_id: str, db: AsyncSession) -> dict:
    from db.database import Base

    record_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    # 直接用 raw SQL 写入，避免 ORM 复杂依赖
    query = """
        INSERT INTO dose_records
          (id, user_id, plan_id, reminder_id, drug_name, dosage,
           scheduled_time, actual_time, result, confirmed_by,
           delay_seconds, bead_open_detected, created_at)
        VALUES
          (:id, :user_id, :plan_id, :reminder_id, :drug_name, :dosage,
           :scheduled_time, :actual_time, :result, :confirmed_by,
           :delay_seconds, :bead_open_detected, :created_at)
    """
    scheduled = params.get("scheduled_time")
    actual = params.get("actual_time")
    result_val = params.get("result", "ontime")

    delay = None
    if scheduled and actual and result_val != "missed":
        try:
            s = datetime.fromisoformat(str(scheduled))
            a = datetime.fromisoformat(str(actual))
            delay = int((a - s).total_seconds())
        except Exception:
            pass

    await db.execute(
        __import__("sqlalchemy").text(query),
        {
            "id": record_id,
            "user_id": user_id,
            "plan_id": params.get("plan_id"),
            "reminder_id": params.get("reminder_id"),
            "drug_name": params.get("drug_name", ""),
            "dosage": params.get("dosage", ""),
            "scheduled_time": scheduled or now.isoformat(),
            "actual_time": actual,
            "result": result_val,
            "confirmed_by": params.get("confirmed_by", "user_tap"),
            "delay_seconds": delay,
            "bead_open_detected": params.get("bead_open_detected", False),
            "created_at": now.isoformat(),
        },
    )

    # 取消漏服计时器
    reminder_id = params.get("reminder_id", "")
    if reminder_id and result_val != "missed":
        await cancel_missed_check(reminder_id)

    logger.info("dose_record_archived", record_id=record_id, result=result_val)
    return {"success": True, "record_id": record_id, "result": result_val}


# ── wakemate.pushFamily ───────────────────────────────────────
async def _push_family(params: dict, user_id: str, db: AsyncSession) -> dict:
    from services.push_service import should_suppress_push, send_fcm_push
    from db.redis_client import incr_family_push_count, get_family_push_count

    # 查询用户的家属设置
    settings_query = """
        SELECT us.family_push_enabled, us.quiet_start, us.quiet_end,
               us.daily_push_limit, u.id as caregiver_id
        FROM user_settings us
        JOIN users caregiver ON caregiver.patient_id = :user_id
        JOIN users u ON u.id = caregiver.id
        WHERE us.user_id = :user_id
        LIMIT 1
    """
    # 简化：直接查 user_settings
    check_quiet = params.get("check_quiet_hours", True)

    # [MVP 约束] 检查静默时段
    if check_quiet:
        suppressed, scheduled_for = await should_suppress_push(user_id, db)
        if suppressed:
            logger.info("push_suppressed_quiet_hours", user_id=user_id)
            return {
                "success": True,
                "push_sent": False,
                "suppressed_by_quiet_hours": True,
                "scheduled_for": scheduled_for,
            }

    # [MVP 约束] 检查日推送频次上限（默认 5 条/天）
    count = await get_family_push_count(user_id)
    if count >= 5:
        logger.info("push_suppressed_daily_limit", user_id=user_id, count=count)
        return {
            "success": True,
            "push_sent": False,
            "suppressed_by_daily_limit": True,
            "count_today": count,
        }

    # 发送推送
    caregiver_id = params.get("caregiver_user_id")
    body = params.get("body", "")
    event_type = params.get("event_type", "dose_confirmed")

    success = await send_fcm_push(
        user_id=caregiver_id or f"caregiver_of_{user_id}",
        title=params.get("title", "醒伴提醒"),
        body=body,
        data=params.get("data", {}),
        priority=params.get("priority", "normal"),
    )

    await incr_family_push_count(user_id)

    logger.info("push_family_sent", user_id=user_id, event_type=event_type, success=success)
    return {"success": True, "push_sent": success, "suppressed_by_quiet_hours": False}


# ── wakemate.vibrate ──────────────────────────────────────────
async def _vibrate(params: dict, user_id: str, db: AsyncSession) -> dict:
    """
    向绑定手表发送震动指令。
    真实场景：通过 xiaozhi-server 下发 BLE 指令到配对手表。
    当前：记录日志，Mock 成功。
    """
    pattern = params.get("pattern", "short-short-long")
    logger.info("vibrate_command", user_id=user_id, pattern=pattern)
    # TODO: 接入真实手表震动 API（WearOS / watchOS）
    return {"success": True, "delivered": True, "latency_ms": 45, "pattern": pattern}


# ── wakemate.checkQuietHours ──────────────────────────────────
async def _check_quiet_hours(params: dict, user_id: str, db: AsyncSession) -> dict:
    from services.push_service import should_suppress_push
    suppressed, scheduled_for = await should_suppress_push(user_id, db)
    return {"suppressed": suppressed, "scheduled_for": scheduled_for}


# ── 漏服事件处理（被后台任务调用） ───────────────────────────────
async def handle_dose_missed_event(item: dict) -> None:
    """
    被 main.py 的后台任务调用，处理超时漏服。
    item: { reminder_key, plan_id, drug_name, user_id }
    """
    from db.database import AsyncSessionLocal
    from services.push_service import send_fcm_push

    user_id = item.get("user_id", "")
    drug_name = item.get("drug_name", "用药")

    async with AsyncSessionLocal() as db:
        # 归档漏服记录
        await _archive_record(
            {
                "reminder_id": item.get("reminder_key"),
                "plan_id": item.get("plan_id"),
                "drug_name": drug_name,
                "dosage": "",
                "result": "missed",
                "confirmed_by": "timeout_missed",
                "actual_time": None,
            },
            user_id,
            db,
        )
        await db.commit()

    # 推送家属
    await send_fcm_push(
        user_id=f"caregiver_of_{user_id}",
        title="服药提醒",
        body=f"⚠️ {drug_name} 未按时服用，请关注",
        data={"event_type": "dose_missed", "drug_name": drug_name},
        priority="normal",
    )

    logger.info("dose_missed_handled", user_id=user_id, drug=drug_name)
