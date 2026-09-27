"""
db/redis_client.py — Redis 连接 + 漏服延迟队列
醒伴 WakeMate Backend

职责：
  - 会话状态热缓存（device_state）
  - 漏服超时延迟队列（ZADD score=到期时间戳）
  - 推送频次计数（防止家属推送过多）
"""
import json
import time
from typing import Any, Optional

import redis.asyncio as aioredis

from core.config import get_settings

settings = get_settings()

_redis: Optional[aioredis.Redis] = None


async def get_redis() -> aioredis.Redis:
    global _redis
    if _redis is None:
        _redis = await aioredis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
        )
    return _redis


async def close_redis() -> None:
    global _redis
    if _redis:
        await _redis.aclose()
        _redis = None


# ── 漏服延迟队列 ───────────────────────────────────────────────
MISSED_QUEUE_KEY = "wakemate:missed_dose_queue"


async def enqueue_missed_check(
    reminder_key: str,
    plan_id: str,
    drug_name: str,
    user_id: str,
    timeout_seconds: int,
) -> None:
    """将提醒加入漏服超时队列，score = 到期时间戳"""
    r = await get_redis()
    expire_at = time.time() + timeout_seconds
    payload = json.dumps({
        "reminder_key": reminder_key,
        "plan_id": plan_id,
        "drug_name": drug_name,
        "user_id": user_id,
    })
    await r.zadd(MISSED_QUEUE_KEY, {payload: expire_at})


async def cancel_missed_check(reminder_key: str) -> None:
    """用户确认服药，取消漏服计时器"""
    r = await get_redis()
    # 扫描匹配 reminder_key 的成员并删除
    members = await r.zrangebyscore(MISSED_QUEUE_KEY, "-inf", "+inf")
    for m in members:
        try:
            data = json.loads(m)
            if data.get("reminder_key") == reminder_key:
                await r.zrem(MISSED_QUEUE_KEY, m)
                break
        except Exception:
            pass


async def pop_due_missed() -> list[dict]:
    """
    取出所有已到期（score ≤ now）的漏服判定条目。
    由后台定时任务调用（每 30s 轮询一次）。
    """
    r = await get_redis()
    now = time.time()
    members = await r.zrangebyscore(MISSED_QUEUE_KEY, "-inf", str(now))
    result = []
    for m in members:
        try:
            result.append(json.loads(m))
            await r.zrem(MISSED_QUEUE_KEY, m)
        except Exception:
            pass
    return result


# ── 设备状态缓存 ───────────────────────────────────────────────
async def cache_device_state(device_id: str, state: dict, ttl: int = 120) -> None:
    r = await get_redis()
    await r.setex(f"device:{device_id}:state", ttl, json.dumps(state))


async def get_device_state(device_id: str) -> Optional[dict]:
    r = await get_redis()
    raw = await r.get(f"device:{device_id}:state")
    return json.loads(raw) if raw else None


# ── 家属推送频次控制 ─────────────────────────────────────────────
# [MVP 约束] 单日家属推送上限 5 条，防止打扰感超过 3/5
async def incr_family_push_count(user_id: str) -> int:
    """返回当日已推送次数（含本次）"""
    r = await get_redis()
    key = f"push:family:{user_id}:{_today_key()}"
    count = await r.incr(key)
    if count == 1:
        await r.expire(key, 86400)  # 自然日到期
    return count


async def get_family_push_count(user_id: str) -> int:
    r = await get_redis()
    key = f"push:family:{user_id}:{_today_key()}"
    val = await r.get(key)
    return int(val) if val else 0


def _today_key() -> str:
    from datetime import date
    return date.today().isoformat()


# ── 通用缓存 ──────────────────────────────────────────────────
async def set_cache(key: str, value: Any, ttl: int = 300) -> None:
    r = await get_redis()
    await r.setex(key, ttl, json.dumps(value))


async def get_cache(key: str) -> Optional[Any]:
    r = await get_redis()
    raw = await r.get(key)
    return json.loads(raw) if raw else None
