"""
main.py — 醒伴 WakeMate FastAPI 应用入口（更新版）
新增：shop + settings 路由注册
醒时科技 Wakeshift · v1.0-MVP
"""
import asyncio
import structlog
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from core.config import get_settings
from db.database import init_db
from db.redis_client import close_redis, get_redis, pop_due_missed

settings = get_settings()
logger = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("WakeMate backend starting", env=settings.app_env)
    if settings.is_dev:
        await init_db()
    await get_redis()
    task = asyncio.create_task(_missed_dose_worker())
    yield
    task.cancel()
    await close_redis()
    logger.info("WakeMate backend stopped")


async def _missed_dose_worker():
    """
    每 30 秒轮询漏服延迟队列。
    [MVP 约束] 头号风险：推送通道稳定性
    """
    from services.mcp_executor import handle_dose_missed_event
    while True:
        try:
            due_items = await pop_due_missed()
            for item in due_items:
                logger.info("missed_dose_triggered", reminder_key=item.get("reminder_key"))
                await handle_dose_missed_event(item)
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error("missed_dose_worker_error", error=str(e))
        await asyncio.sleep(30)


app = FastAPI(
    title="醒伴 WakeMate API",
    description="醒时科技 Wakeshift · 用药管理 + 小醒 AI 陪伴 + 硬件商城",
    version="1.0.0-mvp",
    lifespan=lifespan,
    docs_url="/docs" if settings.is_dev else None,
    redoc_url="/redoc" if settings.is_dev else None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error("unhandled_exception", path=str(request.url), error=str(exc))
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"error": "内部服务器错误", "detail": str(exc) if settings.is_dev else None},
    )


# ── 路由注册 ──────────────────────────────────────────────────────
from routers import auth, chat, plans, records, device, badge, shop, settings as settings_router

app.include_router(auth.router,             prefix="/api/auth",     tags=["鉴权"])
app.include_router(plans.router,            prefix="/api/plans",    tags=["用药计划"])
app.include_router(records.router,          prefix="/api/records",  tags=["服药记录"])
app.include_router(device.router,           prefix="/api/device",   tags=["硬件设备"])
app.include_router(shop.router,             prefix="/api/shop",     tags=["硬件商城"])
app.include_router(settings_router.router,  prefix="/api/settings", tags=["用户设置"])
app.include_router(badge.router,                                     tags=["胸牌/急救"])

# OpenAI 兼容接口（直接挂 /v1）
from routers import chat
app.include_router(chat.router, tags=["小醒 AI 对话"])


@app.get("/health", tags=["系统"])
async def health_check():
    return {
        "status": "ok",
        "service": "WakeMate API",
        "version": "1.0.0-mvp",
        "mock_mode": settings.xiaozhi_mock_mode,
        "routes": [
            "POST /api/auth/otp",
            "POST /api/auth/login",
            "GET  /api/plans",
            "POST /api/plans",
            "POST /api/records/confirm",
            "GET  /api/records/stats",
            "GET  /api/device",
            "GET  /api/shop/skus",
            "GET  /api/shop/models",
            "POST /api/shop/orders",
            "GET  /api/settings",
            "PUT  /api/settings",
            "POST /v1/chat/completions",
            "GET  /badge/{token}",
            "GET  /emergency/{token}",
        ],
    }


@app.get("/", tags=["系统"])
async def root():
    return {"message": "醒伴 WakeMate API · 伴醒同行 Wake Together"}
