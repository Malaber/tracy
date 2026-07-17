from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Tracy"
    database_url: str = "sqlite+aiosqlite:///./tracy.db"
    timezone: str = "Europe/Berlin"


settings = Settings()
