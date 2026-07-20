from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text


def _config(database_url: str) -> Config:
    config = Config("alembic.ini")
    config.set_main_option("script_location", "alembic")
    config.set_main_option("sqlalchemy.url", database_url)
    return config


def test_passkey_migration_preserves_legacy_tracker_data(tmp_path):
    database_url = f"sqlite:///{tmp_path / 'legacy.db'}"
    config = _config(database_url)
    command.upgrade(config, "0001_initial")

    engine = create_engine(database_url)
    with engine.begin() as connection:
        connection.execute(
            text(
                "INSERT INTO work_entries "
                "(work_date, check_out_next_day, notes) "
                "VALUES ('2026-07-18', 0, 'legacy')"
            )
        )

    command.upgrade(config, "head")

    with engine.connect() as connection:
        assert (
            connection.execute(text("SELECT user_id FROM preferences WHERE id = 1")).scalar_one()
            is None
        )
        assert (
            connection.execute(
                text("SELECT user_id FROM work_entries WHERE notes = 'legacy'")
            ).scalar_one()
            is None
        )
        assert {"users", "passkeys", "auth_sessions"} <= set(inspect(connection).get_table_names())
    engine.dispose()
