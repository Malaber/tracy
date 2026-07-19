"""Add passkey authentication and user-scoped tracker data."""

from alembic import op
import sqlalchemy as sa


revision = "0002_add_passkey_auth"
down_revision = "0001_initial"
branch_labels = None
depends_on = None

NAMING_CONVENTION = {
    "ix": "ix_%(column_0_label)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
}


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(length=255), nullable=False),
        sa.Column("display_name", sa.String(length=120), nullable=False),
        sa.Column("is_admin", sa.Boolean(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("email"),
    )
    op.create_table(
        "passkeys",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("credential_id", sa.String(length=255), nullable=False),
        sa.Column("public_key", sa.LargeBinary(), nullable=False),
        sa.Column("sign_count", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("credential_id"),
    )
    op.create_index("ix_passkeys_user_id", "passkeys", ["user_id"])
    op.create_table(
        "auth_sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_auth_sessions_user_id", "auth_sessions", ["user_id"])

    with op.batch_alter_table(
        "preferences", naming_convention=NAMING_CONVENTION
    ) as batch_op:
        batch_op.add_column(sa.Column("user_id", sa.Uuid(), nullable=True))
        batch_op.create_foreign_key(
            "fk_preferences_user_id_users", "users", ["user_id"], ["id"], ondelete="CASCADE"
        )
        batch_op.create_unique_constraint("uq_preferences_user_id", ["user_id"])
        batch_op.create_index("ix_preferences_user_id", ["user_id"])

    if op.get_bind().dialect.name == "postgresql":
        op.execute(
            sa.text(
                "SELECT setval(pg_get_serial_sequence('preferences', 'id'), "
                "COALESCE((SELECT MAX(id) FROM preferences), 1), true)"
            )
        )

    with op.batch_alter_table(
        "work_entries", naming_convention=NAMING_CONVENTION
    ) as batch_op:
        batch_op.add_column(sa.Column("user_id", sa.Uuid(), nullable=True))
        batch_op.drop_constraint("uq_work_entries_work_date", type_="unique")
        batch_op.create_foreign_key(
            "fk_work_entries_user_id_users", "users", ["user_id"], ["id"], ondelete="CASCADE"
        )
        batch_op.create_unique_constraint(
            "uq_work_entries_user_date", ["user_id", "work_date"]
        )
        batch_op.create_index("ix_work_entries_user_id", ["user_id"])


def downgrade() -> None:
    with op.batch_alter_table(
        "work_entries", naming_convention=NAMING_CONVENTION
    ) as batch_op:
        batch_op.drop_index("ix_work_entries_user_id")
        batch_op.drop_constraint("uq_work_entries_user_date", type_="unique")
        batch_op.drop_constraint("fk_work_entries_user_id_users", type_="foreignkey")
        batch_op.drop_column("user_id")
        batch_op.create_unique_constraint("uq_work_entries_work_date", ["work_date"])

    with op.batch_alter_table(
        "preferences", naming_convention=NAMING_CONVENTION
    ) as batch_op:
        batch_op.drop_index("ix_preferences_user_id")
        batch_op.drop_constraint("uq_preferences_user_id", type_="unique")
        batch_op.drop_constraint("fk_preferences_user_id_users", type_="foreignkey")
        batch_op.drop_column("user_id")

    op.drop_index("ix_auth_sessions_user_id", table_name="auth_sessions")
    op.drop_table("auth_sessions")
    op.drop_index("ix_passkeys_user_id", table_name="passkeys")
    op.drop_table("passkeys")
    op.drop_table("users")
