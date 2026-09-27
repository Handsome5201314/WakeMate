"""
routers/deps.py — FastAPI 公共依赖注入
醒伴 WakeMate Backend
"""
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from core.security import decode_access_token

_bearer = HTTPBearer(auto_error=True)


async def get_current_user_id(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> str:
    """从 Bearer Token 中提取 user_id（sub 字段）"""
    try:
        payload = decode_access_token(credentials.credentials)
        user_id: str = payload.get("sub", "")
        if not user_id:
            raise ValueError("empty sub")
        return user_id
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="无效的 Token 或已过期",
            headers={"WWW-Authenticate": "Bearer"},
        )


async def get_current_user_role(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> dict:
    """返回 {user_id, role}"""
    try:
        payload = decode_access_token(credentials.credentials)
        return {"user_id": payload["sub"], "role": payload.get("role", "patient")}
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="无效的 Token 或已过期",
        )
