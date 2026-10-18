"""Persist encrypted XiaoZhi endpoint configuration and connector state."""

from alembic import op
import sqlalchemy as sa

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "mcp_connections",
        sa.Column("binding_id", sa.String(36), nullable=False),
        sa.Column("encrypted_config", sa.Text(), nullable=False),
        sa.Column("endpoint_hash", sa.String(64), nullable=False),
        sa.Column("generation", sa.Integer(), nullable=False),
        sa.Column("state", sa.String(20), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("heartbeat", sa.DateTime(timezone=True), nullable=True),
        sa.Column("connected_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error", sa.String(60), nullable=True),
        sa.ForeignKeyConstraint(
            ["binding_id"], ["mcp_bindings.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("binding_id"),
        sa.UniqueConstraint("endpoint_hash"),
    )


def downgrade():
    op.drop_table("mcp_connections")
