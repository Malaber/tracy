"""Add short-lived, single-use native app authorization codes."""

from alembic import op
import sqlalchemy as sa

revision = "0004_mobile_authorization"
down_revision = "0003_add_days_off"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "mobile_authorizations",
        sa.Column("code_hash", sa.String(64), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("challenge", sa.String(43), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_mobile_authorizations_expires_at", "mobile_authorizations", ["expires_at"])


def downgrade() -> None:
    op.drop_index("ix_mobile_authorizations_expires_at", "mobile_authorizations")
    op.drop_table("mobile_authorizations")
