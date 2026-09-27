"""
core/config.py — 醒伴 WakeMate 后端配置
pydantic-settings 读取环境变量，支持 .env 文件
"""
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    # 应用
    app_env: str = "development"
    app_host: str = "0.0.0.0"
    app_port: int = 8000
    app_secret_key: str = "dev-secret-change-in-production"

    # JWT
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 10080  # 7 天

    # 数据库
    database_url: str = "postgresql+asyncpg://wakemate:password@localhost:5432/wakemate_db"

    # Redis
    redis_url: str = "redis://localhost:6379/0"

    # xiaozhi-server
    # [IS_MOCK_MODE 开关] 设为 True 时使用 mock 响应，不真实调用 xiaozhi-server
    # 设为 False 时连接 XIAOZHI_WS_URL 真实服务
    xiaozhi_mock_mode: bool = True
    xiaozhi_ws_url: str = "wss://your-xiaozhi-server.com/ws"
    xiaozhi_api_key: str = "your-key"
    xiaozhi_default_model: str = "xiaoxing-v1"

    # FCM
    fcm_credentials_file: str = "./firebase-credentials.json"

    # 业务参数
    # [MVP 约束] 漏服超时：生产 1800s，演示 120s
    missed_dose_timeout_seconds: int = 1800

    # CORS
    cors_origins: str = "http://localhost:3000"

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",")]

    # 日志
    log_level: str = "INFO"

    @property
    def is_dev(self) -> bool:
        return self.app_env == "development"


@lru_cache
def get_settings() -> Settings:
    return Settings()
