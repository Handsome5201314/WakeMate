from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid")


class UserCreate(Input):
    phone: str = Field(pattern=r"^1[3-9]\d{9}$")
    display_name: str = Field(min_length=1, max_length=100)
    role: Literal["patient", "caregiver"] = "patient"
    password: str = Field(min_length=12, max_length=128)
    timezone: str = "Asia/Shanghai"

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError("Unknown IANA timezone") from exc
        return value


class RegisterInput(Input):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_]{3,32}$")
    password: str = Field(min_length=12, max_length=128)
    display_name: str | None = Field(default=None, max_length=100)
    timezone: str = "Asia/Shanghai"

    @field_validator("username", mode="before")
    @classmethod
    def normalized_username(cls, value):
        if not isinstance(value, str):
            return value
        return value.strip()

    @field_validator("display_name")
    @classmethod
    def normalized_display_name(cls, value):
        if value is not None:
            value = value.strip()
            if not value:
                raise ValueError("Display name cannot be blank")
        return value

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        return UserCreate.valid_zone(value)


class PlanInput(Input):
    drug_name: str = Field(min_length=1, max_length=100)
    dosage: str = Field(min_length=1, max_length=50)
    times: list[str] = Field(min_length=1, max_length=12)
    note: str | None = Field(default=None, max_length=2000)
    color: str = Field(default="#2C4A7E", pattern=r"^#[0-9A-Fa-f]{6}$")
    active: bool = True
    timezone: str | None = None

    @field_validator("times")
    @classmethod
    def valid_times(cls, values):
        from datetime import time

        for value in values:
            if len(value) != 5 or value[2] != ":":
                raise ValueError("Time must be HH:MM")
            time.fromisoformat(value)
        return sorted(set(values))

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        return UserCreate.valid_zone(value) if value else value


class ConfirmInput(Input):
    dose_instance_id: str | None = None
    reminder_id: str | None = None
    plan_id: str | None = None
    drug_name: str | None = None
    scheduled_time: datetime | None = None
    confirmed_by: Literal["user_tap", "user_voice"] = "user_tap"


class CorrectionInput(Input):
    status: Literal["confirmed", "pending"]
    reason: str = Field(min_length=3, max_length=1000)


class SettingsInput(Input):
    family_push_enabled: bool | None = None
    quiet_start: str | None = None
    quiet_end: str | None = None
    daily_push_limit: int | None = Field(default=None, ge=1, le=20)
    snooze_minutes: int | None = Field(default=None, ge=5, le=60)
    max_snooze_count: int | None = Field(default=None, ge=0, le=10)

    @field_validator("quiet_start", "quiet_end")
    @classmethod
    def valid_time(cls, value):
        if value:
            PlanInput.valid_times([value])
        return value


class ProfileInput(Input):
    display_name: str | None = Field(default=None, min_length=1, max_length=100)
    timezone: str | None = Field(default=None, min_length=1, max_length=60)

    @field_validator("display_name")
    @classmethod
    def valid_name(cls, value):
        if value is not None:
            value = value.strip()
            if not value:
                raise ValueError("Display name cannot be blank")
        return value

    @field_validator("timezone")
    @classmethod
    def valid_zone(cls, value):
        return UserCreate.valid_zone(value) if value is not None else value


class DeviceInput(Input):
    device_sn: str = Field(min_length=1, max_length=64)
    device_type: str = Field(default="pillbox", max_length=40)
    bead_total: int = Field(default=2, ge=1, le=20)
    firmware_ver: str | None = Field(default=None, max_length=80)


class DeviceEventInput(Input):
    event_id: str = Field(min_length=1, max_length=120)
    kind: Literal["lid_open", "lid_close", "heartbeat"]
    occurred_at: datetime
    dose_instance_id: str | None = None
    battery: int | None = Field(default=None, ge=0, le=100)
    bead_remain: int | None = Field(default=None, ge=0, le=20)
