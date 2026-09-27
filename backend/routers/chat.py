"""
routers/chat.py — OpenAI 兼容 AI 对话接口
POST /v1/chat/completions（流式 SSE + 非流式）
醒伴 WakeMate Backend

APP 只认这一个接口，后端内部路由到 xiaozhi-server Agent。
换底层模型只改后端，APP 代码零改动。
"""
import json
import time
import uuid

import structlog
from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse, JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession

from db.database import get_db
from models.schemas import ChatCompletionRequest, ChatCompletionResponse, ChatMessage, ChatChoice, ChatUsage
from routers.deps import get_current_user_id
from services.xiaozhi_client import chat_stream_response
from services.mcp_executor import extract_mcp_calls, execute_mcp_calls

router = APIRouter()
logger = structlog.get_logger()


@router.post("/v1/chat/completions", summary="小醒 AI 对话（OpenAI 兼容）")
async def chat_completions(
    req: ChatCompletionRequest,
    user_id: str = Depends(get_current_user_id),
    db: AsyncSession = Depends(get_db),
):
    """
    OpenAI 兼容接口。
    - stream=true  → SSE 流式响应（Flutter 端逐字渲染）
    - stream=false → 完整 JSON 响应

    醒伴扩展字段（response 中包含）：
    - xiaoxing_pose：小醒当前姿态 gentle/calm/soothe
    - xiaoxing_intent：识别的用户意图
    - mcp_calls：已执行的 MCP 工具调用结果
    """
    messages = [m.model_dump() for m in req.messages]

    if req.stream:
        return StreamingResponse(
            _stream_generator(req, user_id, messages, db),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            },
        )
    else:
        return await _non_stream_response(req, user_id, messages, db)


async def _stream_generator(
    req: ChatCompletionRequest,
    user_id: str,
    messages: list[dict],
    db: AsyncSession,
):
    """SSE 流式生成器，转发 xiaozhi-server 的 chunk"""
    full_text = ""
    pose = "calm"
    intent = "general"

    async for chunk_str in chat_stream_response(
        user_id=user_id,
        messages=messages,
        session_type=req.session_type.value,
    ):
        if chunk_str.startswith("data: [DONE]"):
            break
        if chunk_str.startswith("data: "):
            try:
                data = json.loads(chunk_str[6:])
                delta = data.get("choices", [{}])[0].get("delta", {})
                full_text += delta.get("content", "")
                pose = data.get("xiaoxing_pose", pose)
                intent = data.get("xiaoxing_intent", intent)
            except Exception:
                pass
        yield chunk_str

    # 流结束后，处理 MCP 工具调用（在 SSE 中额外发一个 meta chunk）
    mcp_calls = extract_mcp_calls(full_text)
    if mcp_calls:
        mcp_results = await execute_mcp_calls(mcp_calls, user_id, db)
        meta = {
            "id": f"wm-{uuid.uuid4().hex[:8]}",
            "object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "xiaoxing_pose": pose,
            "xiaoxing_intent": intent,
            "mcp_results": mcp_results,
        }
        yield f"data: {json.dumps(meta, ensure_ascii=False)}\n\n"

    yield "data: [DONE]\n\n"
    logger.info("chat_stream_done", user_id=user_id, intent=intent, pose=pose)


async def _non_stream_response(
    req: ChatCompletionRequest,
    user_id: str,
    messages: list[dict],
    db: AsyncSession,
) -> JSONResponse:
    """非流式：收集完整响应后返回"""
    full_text = ""
    pose = "calm"
    intent = "general"

    async for chunk_str in chat_stream_response(
        user_id=user_id,
        messages=messages,
        session_type=req.session_type.value,
    ):
        if chunk_str.startswith("data: [DONE]"):
            break
        if chunk_str.startswith("data: "):
            try:
                data = json.loads(chunk_str[6:])
                delta = data.get("choices", [{}])[0].get("delta", {})
                full_text += delta.get("content", "")
                pose = data.get("xiaoxing_pose", pose)
                intent = data.get("xiaoxing_intent", intent)
            except Exception:
                pass

    mcp_calls = extract_mcp_calls(full_text)
    mcp_results = []
    if mcp_calls:
        mcp_results = await execute_mcp_calls(mcp_calls, user_id, db)

    response = {
        "id": f"wm-{uuid.uuid4().hex[:8]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": req.model,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": full_text},
            "finish_reason": "stop",
        }],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        "xiaoxing_pose": pose,
        "xiaoxing_intent": intent,
        "mcp_results": mcp_results,
    }
    return JSONResponse(content=response)
