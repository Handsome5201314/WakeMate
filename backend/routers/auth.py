"""
routers/auth.py — 鉴权路由（修复版）
修复：_bearer_header 引用错误，改用标准 HTTPBearer 依赖
醒伴 WakeMate Backend · 醒时科技 Wakeshift
"""
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from core.config import get_settings
from core.security import create_access_token, decode_access_token
from db.database import get_db
from db.redis_client import get_cache, set_cache
from models.schemas import MessageOut, OTPRequest, PhoneLoginRequest, TokenResponse

router = APIRouter()
settings = get_settings()
_bearer = HTTPBearer(auto_error=True)


# ── 发送 OTP ──────────────────────────────────────────────────────
@router.post("/otp", response_model=MessageOut, summary="发送验证码")
async def send_otp(req: OTPRequest):
    """
    生产环境：接入短信服务（阿里云/腾讯云）。
    开发环境：固定验证码 123456，存入 Redis 5 分钟。
    """
    otp = "123456" if settings.is_dev else _generate_otp()
    await set_cache(f"otp:{req.phone}", otp, ttl=300)

    if not settings.is_dev:
        # TODO: 调用短信 API
        # await send_sms(req.phone, f"您的验证码是 {otp}，5分钟内有效。")
        pass

    return MessageOut(
        message="验证码已发送",
        data={"otp": otp} if settings.is_dev else None,
    )


# ── 登录 ──────────────────────────────────────────────────────────
@router.post("/login", response_model=TokenResponse, summary="手机号登录")
async def login(req: PhoneLoginRequest, db: AsyncSession = Depends(get_db)):
    # 校验 OTP
    cached_otp = await get_cache(f"otp:{req.phone}")
    valid = (cached_otp and cached_otp == req.otp) or (settings.is_dev and req.otp == "123456")
    if not valid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="验证码错误或已过期",
        )

    # 查找或创建用户
    result = await db.execute(
        text("SELECT id, role FROM users WHERE phone = :phone AND deleted_at IS NULL"),
        {"phone": req.phone},
    )
    row = result.fetchone()

    if row:
        user_id, role = str(row.id), row.role
    else:
        user_id = str(uuid.uuid4())
        role    = "patient"
        display_name = f"用户{req.phone[-4:]}"
        now = datetime.now(timezone.utc).isoformat()
        await db.execute(
            text("""
                INSERT INTO users (id, phone, display_name, role, created_at, updated_at)
                VALUES (:id, :phone, :name, :role, :now, :now)
            """),
            {"id": user_id, "phone": req.phone, "name": display_name, "role": role, "now": now},
        )
        await db.execute(
            text("INSERT INTO user_settings (user_id) VALUES (:uid) ON CONFLICT DO NOTHING"),
            {"uid": user_id},
        )

    token = create_access_token(subject=user_id, role=role)
    return TokenResponse(
        access_token=token,
        user_id=user_id,
        role=role,
        expires_in=settings.jwt_expire_minutes * 60,
    )


# ── FCM Token 上报（修复：使用标准 HTTPBearer） ────────────────────
@router.post("/fcm-token", response_model=MessageOut, summary="上报 FCM 推送 Token")
async def update_fcm_token(
    body: dict,
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
):
    try:
        payload = decode_access_token(credentials.credentials)
        user_id = payload["sub"]
    except Exception:
        raise HTTPException(status_code=401, detail="无效的 Token")

    fcm_token = body.get("fcm_token", "").strip()
    if not fcm_token:
        raise HTTPException(status_code=400, detail="fcm_token 不能为空")

    from services.push_service import save_fcm_token
    await save_fcm_token(user_id, fcm_token)
    return MessageOut(message="FCM Token 已更新")


# ── 工具函数 ──────────────────────────────────────────────────────
def _generate_otp() -> str:
    import random
    return str(random.randint(100000, 999999))
