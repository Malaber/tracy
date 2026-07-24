"""Add personal days off."""

from alembic import op
import sqlalchemy as sa


revision = "0003_add_days_off"
down_revision = "0002_add_passkey_auth"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "days_off",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("day_off_date", sa.Date(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "day_off_date", name="uq_days_off_user_date"),
    )


def downgrade() -> None:
    op.drop_table("days_off")
