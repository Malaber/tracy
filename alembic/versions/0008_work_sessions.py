"""Timed project work sessions."""
import sqlalchemy as sa
from alembic import op

revision = "0008_work_sessions"
down_revision = "0007_projects"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("work_entries", sa.Column("sessions", sa.JSON(), nullable=True))


def downgrade():
    op.drop_column("work_entries", "sessions")
