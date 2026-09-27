"""
models/schemas.py — 所有 Pydantic 请求/响应 Schema
醒伴 WakeMate Backend
"""
from __future__ import annotations

import uuid
from datetime import datetime, time
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, EmailStr, Field, field_validator


# ── 枚举 ──────────────────────────────────────────────────────

class DoseResult(str, Enum):
    ontime = "ontime"
    late   = "late"
    missed = "missed"

class ConfirmedBy(str, Enum):
    user_tap         = "user_tap"
    agent_inference  = "agent_inference"
    timeout_missed   = "timeout_missed"
    caregiver        = "caregiver"

class PushEventType(str, Enum):
    dose_confirmed = "dose_confirmed"
    dose_missed    = "dose_missed"
    battery_low    = "battery_low"
    daily_summary  = "daily_summary"

class XiaoxingPose(str, Enum):
    gentle = "gentle"   # 温柔提醒
    calm   = "calm"     # 轻声提示
    soothe = "soothe"   # 安心安抚

class DeviceType(str, Enum):
    clasp_bead      = "clasp_bead"       # 智能扣头药珠
    desk_companion  = "desk_companion"   # 桌面摆件
    badge           = "badge"            # 电子胸牌

class SessionType(str, Enum):
    patient    = "patient"
    caregiver  = "caregiver"


# ── Auth ──────────────────────────────────────────────────────

class PhoneLoginRequest(BaseModel):
    phone: str = Field(..., pattern=r"^1[3-9]\d{9}$", description="手机号")
    otp: str = Field(..., min_length=4, max_length=6, description="验证码")

class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user_id: str
    role: str
    expires_in: int  # 秒

class OTPRequest(BaseModel):
    phone: str = Field(..., pattern=r"^1[3-9]\d{9}$")


# ── User ──────────────────────────────────────────────────────

class UserBase(BaseModel):
    display_name: str = Field(default="用户", max_length=50)
    timezone: str = Field(default="Asia/Shanghai")

class UserCreate(UserBase):
    phone: str
    role: str = "patient"

class UserOut(UserBase):
    id: uuid.UUID
    phone: Optional[str] = None
    role: str
    created_at: datetime

    model_config = {"from_attributes": True}


# ── UserSettings ──────────────────────────────────────────────

class UserSettingsUpdate(BaseModel):
    family_push_enabled: Optional[bool] = None
    quiet_start: Optional[str] = None   # "HH:MM"
    quiet_end: Optional[str] = None     # "HH:MM"
    daily_push_limit: Optional[int] = Field(None, ge=1, le=20)
    snooze_minutes: Optional[int] = Field(None, ge=5, le=60)

class UserSettingsOut(BaseModel):
    family_push_enabled: bool
    quiet_start: str
    quiet_end: str
    daily_push_limit: int
    snooze_minutes: int
    max_snooze_count: int

    model_config = {"from_attributes": True}


# ── Device ────────────────────────────────────────────────────

class DeviceRegister(BaseModel):
    device_sn: str = Field(..., max_length=64)
    device_type: DeviceType = DeviceType.clasp_bead
    firmware_ver: Optional[str] = None
    bead_total: int = Field(default=7, ge=1, le=20)

class DeviceStateUpdate(BaseModel):
    """ESP32 上报心跳时使用"""
    battery: int = Field(..., ge=0, le=100)
    bead_remain: int = Field(..., ge=0)
    rtc_drift_ms: int = 0
    watch_connected: bool = False

class DeviceOut(BaseModel):
    id: uuid.UUID
    device_sn: str
    device_type: str
    firmware_ver: Optional[str]
    bead_total: int
    last_sync_at: Optional[datetime]
    state: Optional[dict] = None

    model_config = {"from_attributes": True}


# ── MedicationPlan ────────────────────────────────────────────

class PlanCreate(BaseModel):
    drug_name: str = Field(..., max_length=100)
    dosage: str = Field(..., max_length=50)
    times: list[str] = Field(..., description="服药时间列表 ['HH:MM', ...]")
    note: Optional[str] = None
    color: str = Field(default="#2C4A7E", pattern=r"^#[0-9A-Fa-f]{6}$")

    @field_validator("times")
    @classmethod
    def validate_times(cls, v: list[str]) -> list[str]:
        import re
        for t in v:
            if not re.match(r"^\d{2}:\d{2}$", t):
                raise ValueError(f"时间格式错误：{t}，应为 HH:MM")
        return sorted(set(v))  # 去重并排序

class PlanUpdate(PlanCreate):
    active: Optional[bool] = None

class PlanOut(BaseModel):
    id: uuid.UUID
    drug_name: str
    dosage: str
    times: list[str]
    note: Optional[str]
    color: str
    active: bool
    synced_to_hw: bool
    created_at: datetime

    model_config = {"from_attributes": True}


# ── DoseRecord ────────────────────────────────────────────────

class DoseConfirmRequest(BaseModel):
    reminder_id: str
    plan_id: str
    drug_name: str
    scheduled_time: datetime
    confirmed_by: ConfirmedBy = ConfirmedBy.user_tap

class DoseMissedRequest(BaseModel):
    reminder_id: str
    plan_id: str
    drug_name: str
    scheduled_time: datetime

class DoseRecordOut(BaseModel):
    id: uuid.UUID
    drug_name: str
    dosage: str
    scheduled_time: datetime
    actual_time: Optional[datetime]
    result: DoseResult
    confirmed_by: ConfirmedBy
    delay_seconds: Optional[int]
    created_at: datetime

    model_config = {"from_attributes": True}

class DailyStatsOut(BaseModel):
    date: str
    total: int
    ontime: int
    late: int
    missed: int
    rate: float  # 0.0 - 100.0
    streak_days: int


# ── OpenAI Compatible Chat ────────────────────────────────────

class ChatMessage(BaseModel):
    role: str  # system | user | assistant | tool
    content: str
    name: Optional[str] = None

class ChatCompletionRequest(BaseModel):
    """POST /v1/chat/completions — OpenAI 兼容接口"""
    model: str = "xiaoxing-v1"
    messages: list[ChatMessage]
    stream: bool = False
    temperature: Optional[float] = Field(None, ge=0, le=2)
    max_tokens: Optional[int] = None
    user: Optional[str] = None  # user_id，后端据此找对应 Agent 会话

    # 醒伴扩展字段
    session_type: SessionType = SessionType.patient
    pose: Optional[XiaoxingPose] = None  # 指定姿态（可选）

class ChatChoice(BaseModel):
    index: int = 0
    message: ChatMessage
    finish_reason: str = "stop"

class ChatUsage(BaseModel):
    prompt_tokens: int = 0
    completion_tokens: int = 0
    total_tokens: int = 0

class ChatCompletionResponse(BaseModel):
    id: str
    object: str = "chat.completion"
    created: int
    model: str
    choices: list[ChatChoice]
    usage: ChatUsage
    # 醒伴扩展
    xiaoxing_pose: Optional[str] = None
    xiaoxing_intent: Optional[str] = None
    mcp_calls: Optional[list[dict]] = None  # 解析出的 MCP 工具调用


# ── Badge 胸牌/摆件 ───────────────────────────────────────────

class BadgeDataOut(BaseModel):
    """GET /badge/{token} — 供电子胸牌 / 桌面摆件轮询"""
    user_name: str
    today_rate: float        # 今日按时率 0–100
    streak_days: int         # 连续打卡天数
    next_dose_time: Optional[str]   # "HH:MM" 或 None
    next_drug_name: Optional[str]
    toy_light: str           # pending / done / missed
    xiaoxing_pose: str       # gentle / calm / soothe
    # 急救信息（断网时胸牌 Flash 缓存用）
    emergency_name: str
    emergency_phone: str
    medication_summary: str  # "艾司唑仑片 1片·褪黑素 2粒"


# ── Emergency 急救公开页 ──────────────────────────────────────

class EmergencyOut(BaseModel):
    """GET /emergency/{token} — 无需鉴权，QR 码扫描访问"""
    user_name: str
    emergency_contacts: list[dict]  # [{name, phone, relation}]
    current_medications: list[dict]  # [{drug_name, dosage, times, note}]
    medication_warnings: list[str]   # 用药禁忌
    last_updated: datetime


# ── 通用响应 ──────────────────────────────────────────────────

class MessageOut(BaseModel):
    message: str
    data: Optional[Any] = None

class ErrorOut(BaseModel):
    error: str
    detail: Optional[str] = None
