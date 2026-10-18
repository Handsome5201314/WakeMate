"""Record observed delivery times without inventing times for historical records."""

from alembic import op
import sqlalchemy as sa

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "notification_outbox",
        sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index(
        "ix_notification_outbox_delivered_at", "notification_outbox", ["delivered_at"]
    )


def downgrade():
    op.drop_index(
        "ix_notification_outbox_delivered_at", table_name="notification_outbox"
    )
    op.drop_column("notification_outbox", "delivered_at")
