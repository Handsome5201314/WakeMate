from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="WAKEMATE_", extra="ignore")
    database_url: str
    secret: str = Field(min_length=32)
    admin_password: str = Field(min_length=12)
    token_seconds: int = 3600
    confirmation_window_seconds: int = 1800
    worker_interval_seconds: int = 15
    environment: str = "local"
    notification_webhook: str = ""
    notification_webhook_token: str = ""
    cors_origins: str = "http://localhost:8090,http://127.0.0.1:8090"


@lru_cache
def get_settings() -> Settings:
    return Settings()
