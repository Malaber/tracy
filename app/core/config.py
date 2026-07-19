from urllib.parse import urlparse

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Tracy"
    secret_key: str = Field(default="development-only-secret-change-me", min_length=32)
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 28
    session_max_age_seconds: int = 60 * 60 * 24 * 180
    session_idle_timeout_seconds: int = 60 * 60 * 24 * 28
    auth_flow_expire_seconds: int = 10 * 60
    database_url: str = "sqlite+aiosqlite:///./tracy.db"
    timezone: str = "Europe/Berlin"
    app_base_url: str | None = None
    secure_cookies: bool = False
    webauthn_rp_id: str | None = None

    @field_validator("app_base_url", mode="before")
    @classmethod
    def normalize_app_base_url(cls, value: object) -> object:
        if not isinstance(value, str):
            return value
        normalized = value.strip().rstrip("/")
        if not normalized:
            return None
        parsed = urlparse(normalized)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("app_base_url must be an http or https origin without a path")
        return normalized


settings = Settings()
