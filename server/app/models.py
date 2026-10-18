from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    JSON,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


def utcnow():
    return datetime.now(timezone.utc)


def new_id():
    return str(uuid4())


class Entity:
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )


class User(Entity, Base):
    __tablename__ = "users"
    username: Mapped[str] = mapped_column(String(100), unique=True)
    phone: Mapped[str | None] = mapped_column(String(20), unique=True, nullable=True)
    display_name: Mapped[str] = mapped_column(String(100))
    password_hash: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(20))
    timezone: Mapped[str] = mapped_column(String(60), default="Asia/Shanghai")
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    settings: Mapped[dict] = mapped_column(JSON, default=dict)


class OTP(Entity, Base):
    __tablename__ = "otp_challenges"
    phone: Mapped[str] = mapped_column(String(20), index=True)
    code_hash: Mapped[str] = mapped_column(String(64))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used: Mapped[bool] = mapped_column(Boolean, default=False)
    attempts: Mapped[int] = mapped_column(Integer, default=0)


class LoginAttempt(Base):
    __tablename__ = "login_attempts"
    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    count: Mapped[int] = mapped_column(Integer, default=0)
    reset_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Plan(Entity, Base):
    __tablename__ = "medication_plans"
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    drug_name: Mapped[str] = mapped_column(String(100))
    dosage: Mapped[str] = mapped_column(String(50))
    times: Mapped[list] = mapped_column(JSON)
    note: Mapped[str | None] = mapped_column(String(2000), nullable=True)
    color: Mapped[str] = mapped_column(String(7), default="#2C4A7E")
    timezone: Mapped[str] = mapped_column(String(60))
    version: Mapped[int] = mapped_column(Integer, default=1)
    version_effective_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class Dose(Entity, Base):
    __tablename__ = "dose_instances"
    __table_args__ = (UniqueConstraint("plan_id", "plan_version", "scheduled_time"),)
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    plan_id: Mapped[str] = mapped_column(ForeignKey("medication_plans.id"))
    plan_version: Mapped[int] = mapped_column(Integer)
    drug_name: Mapped[str] = mapped_column(String(100))
    dosage: Mapped[str] = mapped_column(String(50))
    timezone: Mapped[str] = mapped_column(String(60))
    scheduled_time: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), index=True
    )
    status: Mapped[str] = mapped_column(String(20), default="pending")
    actual_time: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    result: Mapped[str | None] = mapped_column(String(20), nullable=True)
    confirmed_by: Mapped[str | None] = mapped_column(String(30), nullable=True)


class Evidence(Entity, Base):
    __tablename__ = "dose_evidence"
    __table_args__ = (UniqueConstraint("patient_id", "idempotency_key"),)
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    dose_id: Mapped[str | None] = mapped_column(
        ForeignKey("dose_instances.id"), nullable=True
    )
    actor_id: Mapped[str] = mapped_column(String(36))
    kind: Mapped[str] = mapped_column(String(30))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    request_id: Mapped[str] = mapped_column(String(64))
    idempotency_key: Mapped[str | None] = mapped_column(String(200), nullable=True)
    payload_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    detail: Mapped[dict] = mapped_column(JSON, default=dict)


class Grant(Entity, Base):
    __tablename__ = "caregiver_grants"
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    caregiver_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    status: Mapped[str] = mapped_column(String(30), default="invited")
    scopes: Mapped[list] = mapped_column(
        JSON, default=lambda: ["records:read", "plans:read", "reminders:read"]
    )
    expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class Device(Entity, Base):
    __tablename__ = "devices"
    device_sn: Mapped[str] = mapped_column(String(64), unique=True)
    device_type: Mapped[str] = mapped_column(String(40), default="pillbox")
    bead_total: Mapped[int] = mapped_column(Integer, default=2)
    firmware_ver: Mapped[str | None] = mapped_column(String(80), nullable=True)
    patient_id: Mapped[str | None] = mapped_column(
        ForeignKey("users.id"), nullable=True, index=True
    )
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    claim_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)
    claim_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_sync_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    ack_versions: Mapped[dict] = mapped_column(JSON, default=dict)
    state: Mapped[dict] = mapped_column(JSON, default=dict)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class DeviceEvent(Entity, Base):
    __tablename__ = "device_events"
    __table_args__ = (UniqueConstraint("device_id", "event_id"),)
    device_id: Mapped[str] = mapped_column(ForeignKey("devices.id"))
    event_id: Mapped[str] = mapped_column(String(120))
    kind: Mapped[str] = mapped_column(String(30))
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    payload_hash: Mapped[str] = mapped_column(String(64))


class Notification(Entity, Base):
    __tablename__ = "notification_outbox"
    __table_args__ = (UniqueConstraint("dose_id", "target_id", "event"),)
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    dose_id: Mapped[str] = mapped_column(ForeignKey("dose_instances.id"))
    target_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    event: Mapped[str] = mapped_column(String(30))
    channel: Mapped[str] = mapped_column(String(30), default="inbox")
    status: Mapped[str] = mapped_column(String(30), default="queued")
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    next_attempt_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    delivered_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
    last_error: Mapped[str | None] = mapped_column(String(100), nullable=True)
    read_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    payload: Mapped[dict] = mapped_column(JSON, default=dict)


class Binding(Entity, Base):
    __tablename__ = "mcp_bindings"
    patient_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    label: Mapped[str] = mapped_column(String(100))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    last_called_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class MCPConnection(Base):
    __tablename__ = "mcp_connections"
    binding_id: Mapped[str] = mapped_column(
        ForeignKey("mcp_bindings.id", ondelete="CASCADE"), primary_key=True
    )
    encrypted_config: Mapped[str] = mapped_column(Text)
    endpoint_hash: Mapped[str] = mapped_column(String(64), unique=True)
    generation: Mapped[int] = mapped_column(Integer, default=1)
    state: Mapped[str] = mapped_column(String(20), default="queued")
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow
    )
    heartbeat: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    connected_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_error: Mapped[str | None] = mapped_column(String(60), nullable=True)


class Audit(Entity, Base):
    __tablename__ = "audit_events"
    actor_id: Mapped[str] = mapped_column(String(36))
    patient_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    action: Mapped[str] = mapped_column(String(60))
    object_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    request_id: Mapped[str] = mapped_column(String(64))
    detail: Mapped[dict] = mapped_column(JSON, default=dict)


class WorkerState(Base):
    __tablename__ = "worker_state"
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    heartbeat: Mapped[datetime] = mapped_column(DateTime(timezone=True))
