"""Frozen initial WakeMate schema; later model changes require new revisions."""

from alembic import op
import sqlalchemy as sa

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "users",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("username", sa.String(100), nullable=False),
        sa.Column("phone", sa.String(20), nullable=True),
        sa.Column("display_name", sa.String(100), nullable=False),
        sa.Column("password_hash", sa.String(200), nullable=False),
        sa.Column("role", sa.String(20), nullable=False),
        sa.Column("timezone", sa.String(60), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("settings", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("username"),
        sa.UniqueConstraint("phone"),
    )
    op.create_table(
        "otp_challenges",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("phone", sa.String(20), nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used", sa.Boolean(), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_otp_challenges_phone", "otp_challenges", ["phone"])
    op.create_table(
        "login_attempts",
        sa.Column("key", sa.String(64), nullable=False),
        sa.Column("count", sa.Integer(), nullable=False),
        sa.Column("reset_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("key"),
    )
    op.create_table(
        "medication_plans",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("drug_name", sa.String(100), nullable=False),
        sa.Column("dosage", sa.String(50), nullable=False),
        sa.Column("times", sa.JSON(), nullable=False),
        sa.Column("note", sa.String(2000), nullable=True),
        sa.Column("color", sa.String(7), nullable=False),
        sa.Column("timezone", sa.String(60), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("version_effective_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_medication_plans_patient_id", "medication_plans", ["patient_id"]
    )
    op.create_table(
        "dose_instances",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("plan_id", sa.String(36), nullable=False),
        sa.Column("plan_version", sa.Integer(), nullable=False),
        sa.Column("drug_name", sa.String(100), nullable=False),
        sa.Column("dosage", sa.String(50), nullable=False),
        sa.Column("timezone", sa.String(60), nullable=False),
        sa.Column("scheduled_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("actual_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("result", sa.String(20), nullable=True),
        sa.Column("confirmed_by", sa.String(30), nullable=True),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["plan_id"], ["medication_plans.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("plan_id", "plan_version", "scheduled_time"),
    )
    op.create_index("ix_dose_instances_patient_id", "dose_instances", ["patient_id"])
    op.create_index(
        "ix_dose_instances_scheduled_time", "dose_instances", ["scheduled_time"]
    )
    op.create_table(
        "dose_evidence",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("dose_id", sa.String(36), nullable=True),
        sa.Column("actor_id", sa.String(36), nullable=False),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("request_id", sa.String(64), nullable=False),
        sa.Column("idempotency_key", sa.String(200), nullable=True),
        sa.Column("payload_hash", sa.String(64), nullable=True),
        sa.Column("detail", sa.JSON(), nullable=False),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["dose_id"], ["dose_instances.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("patient_id", "idempotency_key"),
    )
    op.create_index("ix_dose_evidence_patient_id", "dose_evidence", ["patient_id"])
    op.create_table(
        "caregiver_grants",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("caregiver_id", sa.String(36), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("scopes", sa.JSON(), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["caregiver_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_caregiver_grants_patient_id", "caregiver_grants", ["patient_id"]
    )
    op.create_index(
        "ix_caregiver_grants_caregiver_id", "caregiver_grants", ["caregiver_id"]
    )
    op.create_table(
        "devices",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_sn", sa.String(64), nullable=False),
        sa.Column("device_type", sa.String(40), nullable=False),
        sa.Column("bead_total", sa.Integer(), nullable=False),
        sa.Column("firmware_ver", sa.String(80), nullable=True),
        sa.Column("patient_id", sa.String(36), nullable=True),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("claim_hash", sa.String(64), nullable=True),
        sa.Column("claim_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_sync_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("ack_versions", sa.JSON(), nullable=False),
        sa.Column("state", sa.JSON(), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("device_sn"),
        sa.UniqueConstraint("token_hash"),
    )
    op.create_index("ix_devices_patient_id", "devices", ["patient_id"])
    op.create_table(
        "device_events",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("device_id", sa.String(36), nullable=False),
        sa.Column("event_id", sa.String(120), nullable=False),
        sa.Column("kind", sa.String(30), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload_hash", sa.String(64), nullable=False),
        sa.ForeignKeyConstraint(["device_id"], ["devices.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("device_id", "event_id"),
    )
    op.create_table(
        "notification_outbox",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("dose_id", sa.String(36), nullable=False),
        sa.Column("target_id", sa.String(36), nullable=False),
        sa.Column("event", sa.String(30), nullable=False),
        sa.Column("channel", sa.String(30), nullable=False),
        sa.Column("status", sa.String(30), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_error", sa.String(100), nullable=True),
        sa.Column("read_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["dose_id"], ["dose_instances.id"]),
        sa.ForeignKeyConstraint(["target_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("dose_id", "target_id", "event"),
    )
    op.create_index(
        "ix_notification_outbox_patient_id", "notification_outbox", ["patient_id"]
    )
    op.create_index(
        "ix_notification_outbox_target_id", "notification_outbox", ["target_id"]
    )
    op.create_table(
        "mcp_bindings",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=False),
        sa.Column("label", sa.String(100), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("active", sa.Boolean(), nullable=False),
        sa.Column("last_called_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["patient_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("token_hash"),
    )
    op.create_index("ix_mcp_bindings_patient_id", "mcp_bindings", ["patient_id"])
    op.create_table(
        "audit_events",
        sa.Column("id", sa.String(36), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actor_id", sa.String(36), nullable=False),
        sa.Column("patient_id", sa.String(36), nullable=True),
        sa.Column("action", sa.String(60), nullable=False),
        sa.Column("object_id", sa.String(36), nullable=True),
        sa.Column("request_id", sa.String(64), nullable=False),
        sa.Column("detail", sa.JSON(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "worker_state",
        sa.Column("id", sa.String(20), nullable=False),
        sa.Column("heartbeat", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade():
    for table in (
        "worker_state",
        "audit_events",
        "mcp_bindings",
        "notification_outbox",
        "device_events",
        "devices",
        "caregiver_grants",
        "dose_evidence",
        "dose_instances",
        "medication_plans",
        "login_attempts",
        "otp_challenges",
        "users",
    ):
        op.drop_table(table)
