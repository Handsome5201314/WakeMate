"""
services/xiaozhi_client.py — xiaozhi-server WebSocket 连接客户端
醒伴 WakeMate Backend

[IS_MOCK_MODE 开关]
  xiaozhi_mock_mode = True  → 本地话术库响应，不连真实 server
  xiaozhi_mock_mode = False → 连接 XIAOZHI_WS_URL，转发消息

真实接入步骤：
  1. 在 .env 设置 XIAOZHI_MOCK_MODE=false
  2. 设置 XIAOZHI_WS_URL=wss://your-xiaozhi-server.com/ws
  3. 设置 XIAOZHI_API_KEY=your-key
"""
import asyncio
import json
import random
import time
from typing import AsyncGenerator, Optional

import structlog
import websockets
from websockets.exceptions import ConnectionClosed

from core.config import get_settings

settings = get_settings()
logger = structlog.get_logger()


# ── Mock 话术库（xiaozhi_mock_mode=True 时使用） ───────────────
_MOCK_RESPONSES = {
    "confirmed": [
        "太好了 ✓ 记录已更新，今天这次按时完成了。好好休息，晚安～",
        "做到了！按时服药对你的健康很重要，你做得很好 🌟",
    ],
    "missed": [
        "没关系，有时候忘记是完全正常的。现在补服还来得及，请参考医嘱的补服建议～",
        "慢慢来，今天补上就好。我下次会更早一点提醒你的。",
        "没事哒，比起自责，现在补上更重要。需要我帮你记录一下吗？",
        "嗯，今天漏了一次。没关系，明天继续，一次不影响整体的。",
    ],
    "reminder": [
        "到服药时间啦～ {drug_name} {dosage}，现在可以服用了。今天感觉怎么样？",
    ],
    "sleep": [
        "睡不着的时候，可以试试 4-7-8 呼吸法：吸气 4 秒，屏气 7 秒，呼气 8 秒。可以多练几次哦。",
        "睡前减少手机使用，调暗灯光，保持室温 18-22℃，都有助于入睡～",
    ],
    "device": [
        "醒伴药珠目前在线，如果需要查看详细状态，可以去「我的」→「硬件设备」看看。",
    ],
    "medical_boundary": [
        "剂量调整需要遵医嘱，这个我没办法给建议——但我帮你记录下来，下次复诊时给医生看看。",
        "停药是重要决定，需要和医生一起讨论，不能自行停药哦。",
    ],
    "default": [
        "嗯嗯，我听到你了。有什么关于用药或睡眠的问题，随时告诉我～",
        "我在哦，不管遇到什么都可以和我说 💙",
    ],
    "greet": [
        "嗨～我是小醒，你的小守夜灯 🌙 有什么想聊的吗？",
        "你好呀，我在这里陪着你。今天感觉怎么样？",
    ],
}


def _mock_classify(text: str) -> str:
    t = text.lower()
    if any(k in t for k in ["吃了","服了","已经","拿了","刚喝"]): return "confirmed"
    if any(k in t for k in ["忘了","没吃","漏","错过","没有服"]): return "missed"
    if any(k in t for k in ["睡不着","失眠","睡眠","难睡"]): return "sleep"
    if any(k in t for k in ["设备","药珠","连不上","电量"]): return "device"
    if any(k in t for k in ["副作用","停药","换药","加量","减量","多吃"]): return "medical_boundary"
    if any(k in t for k in ["你好","hi","hello","嗨","开始"]): return "greet"
    return "default"


def _mock_pose(intent: str) -> str:
    return {
        "missed": "soothe",
        "confirmed": "gentle",
        "reminder": "gentle",
        "greet": "gentle",
        "medical_boundary": "calm",
    }.get(intent, "calm")


async def mock_chat_stream(
    messages: list[dict],
    session_type: str = "patient",
    **kwargs,
) -> AsyncGenerator[str, None]:
    """模拟流式输出，逐字 yield SSE chunk"""
    last_user = next(
        (m["content"] for m in reversed(messages) if m["role"] == "user"),
        "你好",
    )
    intent = _mock_classify(last_user)
    pool = _MOCK_RESPONSES.get(intent, _MOCK_RESPONSES["default"])
    text = random.choice(pool)

    # 填充模板变量
    text = text.replace("{drug_name}", "艾司唑仑片").replace("{dosage}", "1片")

    pose = _mock_pose(intent)

    # 模拟打字延迟，逐字 yield
    for char in text:
        chunk = {
            "id": f"mock-{int(time.time())}",
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {"content": char},
                "finish_reason": None,
            }],
            "xiaoxing_pose": pose,
            "xiaoxing_intent": intent,
        }
        yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        await asyncio.sleep(0.03)  # 30ms per char

    # 结束信号
    final = {
        "id": f"mock-{int(time.time())}",
        "object": "chat.completion.chunk",
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
        "xiaoxing_pose": pose,
        "xiaoxing_intent": intent,
    }
    yield f"data: {json.dumps(final, ensure_ascii=False)}\n\n"
    yield "data: [DONE]\n\n"


# ── 真实 xiaozhi-server WebSocket 客户端 ──────────────────────
class XiaozhiClient:
    """
    与 xiaozhi-server 建立 WebSocket 长连接。
    每个 user_id 对应一个独立 Agent 实例（Harmes 框架）。
    """

    def __init__(self):
        self._connections: dict[str, websockets.WebSocketClientProtocol] = {}
        self._lock = asyncio.Lock()

    async def get_connection(self, user_id: str):
        async with self._lock:
            if user_id in self._connections:
                conn = self._connections[user_id]
                if not conn.closed:
                    return conn
            conn = await websockets.connect(
                f"{settings.xiaozhi_ws_url}?user_id={user_id}&api_key={settings.xiaozhi_api_key}",
                ping_interval=30,
                ping_timeout=10,
            )
            self._connections[user_id] = conn
            logger.info("xiaozhi_connected", user_id=user_id)
            return conn

    async def chat_stream(
        self,
        user_id: str,
        messages: list[dict],
        session_type: str = "patient",
        **kwargs,
    ) -> AsyncGenerator[str, None]:
        """向 xiaozhi-server 发送消息，流式接收响应"""
        try:
            conn = await self.get_connection(user_id)
            payload = json.dumps({
                "type": "CHAT",
                "user_id": user_id,
                "session_type": session_type,
                "messages": messages,
                "stream": True,
                **kwargs,
            })
            await conn.send(payload)

            async for raw in conn:
                try:
                    data = json.loads(raw)
                    if data.get("type") == "STREAM_CHUNK":
                        yield f"data: {json.dumps(data['chunk'], ensure_ascii=False)}\n\n"
                    elif data.get("type") == "STREAM_END":
                        yield "data: [DONE]\n\n"
                        break
                except json.JSONDecodeError:
                    continue

        except (ConnectionClosed, ConnectionRefusedError) as e:
            logger.error("xiaozhi_connection_failed", user_id=user_id, error=str(e))
            # 降级到 mock 模式
            async for chunk in mock_chat_stream(messages, session_type):
                yield chunk

    async def close_all(self) -> None:
        for conn in self._connections.values():
            await conn.close()
        self._connections.clear()


# 单例
_client: Optional[XiaozhiClient] = None


def get_xiaozhi_client() -> XiaozhiClient:
    global _client
    if _client is None:
        _client = XiaozhiClient()
    return _client


async def chat_stream_response(
    user_id: str,
    messages: list[dict],
    session_type: str = "patient",
    **kwargs,
) -> AsyncGenerator[str, None]:
    """
    统一入口：根据 IS_MOCK_MODE 决定走 mock 还是真实 xiaozhi-server
    """
    if settings.xiaozhi_mock_mode:
        async for chunk in mock_chat_stream(messages, session_type, **kwargs):
            yield chunk
    else:
        client = get_xiaozhi_client()
        async for chunk in client.chat_stream(user_id, messages, session_type, **kwargs):
            yield chunk
