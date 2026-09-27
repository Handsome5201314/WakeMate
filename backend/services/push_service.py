"""
services/push_service.py — FCM 推送 + 静默时段检查
醒伴 WakeMate Backend

[MVP 风险] 头号风险：推送通道稳定性
三重保险：FCM → WebSocket 下行 → 本地通知预注册
"""
import json
from datetime import datetime, timezone, timedelta
from typing import Optional, Tuple

import structlog

from core.config import get_settings

settings = get_settings()
logger = structlog.get_logger()

# FCM Admin SDK 初始化（懒加载）
_fcm_initialized = False


def _init_fcm():
    global _fcm_initialized
    if _fcm_initialized:
        return
    try:
        import firebase_admin
        from firebase_admin import credentials
        cred = credentials.Certificate(settings.fcm_credentials_file)
        firebase_admin.initialize_app(cred)
        _fcm_initialized = True
        logger.info("fcm_initialized")
    except Exception as e:
        logger.warning("fcm_init_failed", error=str(e), note="将使用 Mock 推送")


async def send_fcm_push(
    user_id: str,
    title: str,
    body: str,
    data: Optional[dict] = None,
    priority: str = "normal",  # normal | high
) -> bool:
    """
    发送 FCM 推送通知。
    失败时记录日志，不抛出异常（推送失败不应阻断主流程）。

    [MVP 约束]
    priority=high 仅限：电量<10% / 连续3次漏服
    其余一律 normal
    """
    if settings.xiaozhi_mock_mode:
        # Mock 模式：只记录日志
        logger.info(
            "mock_push_sent",
            to=user_id, title=title, body=body[:50], priority=priority
        )
        return True

    _init_fcm()

    try:
        from firebase_admin import messaging

        # 查询用户的 FCM token（从 Redis 或 DB）
        fcm_token = await _get_fcm_token(user_id)
        if not fcm_token:
            logger.warning("no_fcm_token", user_id=user_id)
            return False

        msg = messaging.Message(
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
            token=fcm_token,
            android=messaging.AndroidConfig(
                priority="high" if priority == "high" else "normal",
                notification=messaging.AndroidNotification(
                    channel_id="wakemate_reminder",
                    sound="default",
                ),
            ),
        )
        response = messaging.send(msg)
        logger.info("fcm_push_sent", user_id=user_id, message_id=response)
        return True

    except Exception as e:
        logger.error("fcm_push_failed", user_id=user_id, error=str(e))
        return False


async def _get_fcm_token(user_id: str) -> Optional[str]:
    """从 Redis 获取用户的 FCM token"""
    from db.redis_client import get_cache
    return await get_cache(f"fcm_token:{user_id}")


async def save_fcm_token(user_id: str, token: str) -> None:
    """APP 启动时上报 FCM token，存入 Redis"""
    from db.redis_client import set_cache
    await set_cache(f"fcm_token:{user_id}", token, ttl=86400 * 30)  # 30 天
    logger.info("fcm_token_saved", user_id=user_id)


async def should_suppress_push(
    user_id: str,
    db,
) -> Tuple[bool, Optional[str]]:
    """
    检查是否在静默时段，返回 (是否抑制, 计划发送时间)

    [MVP 约束]
    静默时段内的推送压后至 quiet_end 发送，而非直接丢弃。
    """
    try:
        from sqlalchemy import text
        result = await db.execute(
            text("SELECT quiet_start, quiet_end FROM user_settings WHERE user_id = :uid"),
            {"uid": user_id}
        )
        row = result.fetchone()
        if not row:
            return False, None

        quiet_start_str = str(row.quiet_start)  # "HH:MM:SS" or "HH:MM"
        quiet_end_str   = str(row.quiet_end)

        now = datetime.now(timezone.utc).astimezone()
        now_time = now.time().replace(second=0, microsecond=0)

        qs = _parse_time(quiet_start_str)
        qe = _parse_time(quiet_end_str)

        in_quiet = _time_in_range(now_time, qs, qe)
        if not in_quiet:
            return False, None

        # 计算下一个 quiet_end 时间
        tomorrow = now.date() if now_time < qe else (now.date() + timedelta(days=1))
        scheduled_for = datetime.combine(
            tomorrow if qe <= qs else now.date(),
            qe,
            tzinfo=now.tzinfo
        ).isoformat()

        return True, scheduled_for

    except Exception as e:
        logger.warning("quiet_hours_check_failed", error=str(e))
        return False, None


def _parse_time(s: str):
    from datetime import time as dtime
    parts = s.split(":")
    return dtime(int(parts[0]), int(parts[1]))


def _time_in_range(current, start, end):
    """判断 current 是否在 [start, end] 跨午夜区间内"""
    if start <= end:
        return start <= current <= end
    # 跨午夜（如 22:00–07:00）
    return current >= start or current <= end
