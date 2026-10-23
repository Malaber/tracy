"""Project bookings and automatic break provenance."""

import sqlalchemy as sa
from alembic import op

revision = "0007_projects"
down_revision = "0006_passkey_add_links"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "projects",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("name_key", sa.String(240), nullable=False),
        sa.Column("archived", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.UniqueConstraint("user_id", "name_key", name="uq_project_name"),
    )
    op.create_index("ix_projects_user_id", "projects", ["user_id"])
    op.add_column("preferences", sa.Column("default_project_id", sa.Integer()))
    op.add_column("work_entries", sa.Column("default_project_id", sa.Integer()))
    op.add_column(
        "work_entries",
        sa.Column("project_allocations", sa.JSON(), nullable=False, server_default="[]"),
    )
    op.add_column(
        "break_entries",
        sa.Column("automatic", sa.Boolean(), nullable=False, server_default=sa.false()),
    )


def downgrade():
    op.drop_column("break_entries", "automatic")
    op.drop_column("work_entries", "project_allocations")
    op.drop_column("work_entries", "default_project_id")
    op.drop_column("preferences", "default_project_id")
    op.drop_table("projects")
