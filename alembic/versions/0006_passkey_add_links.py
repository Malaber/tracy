"""Admin-issued single-use passkey enrollment links."""

import sqlalchemy as sa
from alembic import op

revision = "0006_passkey_add_links"
down_revision = "0005_entry_sync_revisions"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "passkey_add_links",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("token_hash", sa.String(64), unique=True, nullable=False),
        sa.Column("created_by", sa.Uuid(), sa.ForeignKey("users.id", ondelete="SET NULL")),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True)),
        sa.Column("revoked_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_passkey_add_links_user_id", "passkey_add_links", ["user_id"])


def downgrade():
    op.drop_table("passkey_add_links")
