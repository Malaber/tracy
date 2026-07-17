"""Initial time tracking tables."""

from alembic import op
import sqlalchemy as sa


revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "preferences",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("federal_state", sa.String(length=2), nullable=False),
        sa.Column("daily_target_minutes", sa.Integer(), nullable=False),
        sa.Column("rounding_minutes", sa.Integer(), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "work_entries",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("work_date", sa.Date(), nullable=False),
        sa.Column("check_in_minutes", sa.Integer(), nullable=True),
        sa.Column("check_out_minutes", sa.Integer(), nullable=True),
        sa.Column("check_out_next_day", sa.Boolean(), nullable=False),
        sa.Column("notes", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("work_date"),
    )
    op.create_index("ix_work_entries_work_date", "work_entries", ["work_date"])
    op.create_table(
        "break_entries",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("work_entry_id", sa.Integer(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("mode", sa.String(length=16), nullable=False),
        sa.Column("duration_minutes", sa.Integer(), nullable=True),
        sa.Column("start_minutes", sa.Integer(), nullable=True),
        sa.Column("end_minutes", sa.Integer(), nullable=True),
        sa.CheckConstraint("mode IN ('duration', 'range')", name="ck_break_mode"),
        sa.ForeignKeyConstraint(["work_entry_id"], ["work_entries.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_break_entries_work_entry_id", "break_entries", ["work_entry_id"])
    op.bulk_insert(
        sa.table(
            "preferences",
            sa.column("id", sa.Integer()),
            sa.column("federal_state", sa.String()),
            sa.column("daily_target_minutes", sa.Integer()),
            sa.column("rounding_minutes", sa.Integer()),
        ),
        [{"id": 1, "federal_state": "DE", "daily_target_minutes": 480, "rounding_minutes": 15}],
    )


def downgrade() -> None:
    op.drop_index("ix_break_entries_work_entry_id", table_name="break_entries")
    op.drop_table("break_entries")
    op.drop_index("ix_work_entries_work_date", table_name="work_entries")
    op.drop_table("work_entries")
    op.drop_table("preferences")
