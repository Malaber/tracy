"""Track entry revisions and retry-safe mobile mutations."""

from alembic import op
import sqlalchemy as sa

revision = "0005_entry_sync_revisions"
down_revision = "0004_mobile_authorization"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("work_entries") as batch:
        batch.add_column(sa.Column("revision", sa.String(36), nullable=False, server_default="legacy"))
        batch.add_column(sa.Column("client_mutation_id", sa.String(36), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("work_entries") as batch:
        batch.drop_column("client_mutation_id")
        batch.drop_column("revision")
