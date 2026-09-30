from datetime import UTC, datetime, timedelta
from uuid import UUID

from jose import jwt

from app.core.config import settings


def create_access_token(user_id: UUID, *, session_id: UUID | None = None) -> str:
    expires_at = datetime.now(UTC) + timedelta(minutes=settings.access_token_expire_minutes)
    return jwt.encode(
        {
            "sub": str(user_id),
            "exp": expires_at,
            **({"sid": str(session_id)} if session_id else {}),
        },
        settings.secret_key,
        algorithm=settings.algorithm,
    )
