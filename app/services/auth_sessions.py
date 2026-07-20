from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload
from starlette.requests import HTTPConnection

from app.core.config import settings
from app.models import AuthSession, User


AUTH_SESSION_ID_KEY = "auth_session_id"


def _now_utc() -> datetime:
    return datetime.now(UTC)


def _as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def _auth_session_is_valid(auth_session: AuthSession, now: datetime) -> bool:
    idle_timeout = timedelta(seconds=settings.session_idle_timeout_seconds)
    return (
        _as_utc(auth_session.expires_at) > now
        and _as_utc(auth_session.last_seen_at) > now - idle_timeout
    )


async def create_auth_session(request: HTTPConnection, db: AsyncSession, user: User) -> AuthSession:
    now = _now_utc()
    auth_session = AuthSession(
        user_id=user.id,
        last_seen_at=now,
        expires_at=now + timedelta(seconds=settings.session_max_age_seconds),
    )
    db.add(auth_session)
    await db.commit()
    await db.refresh(auth_session)
    request.session.clear()
    request.session[AUTH_SESSION_ID_KEY] = str(auth_session.id)
    return auth_session


async def revoke_auth_session(request: HTTPConnection, db: AsyncSession) -> None:
    raw_session_id = request.session.pop(AUTH_SESSION_ID_KEY, None)
    if not raw_session_id:
        return
    try:
        session_id = UUID(raw_session_id)
    except ValueError:
        return
    auth_session = await db.get(AuthSession, session_id)
    if auth_session is not None:
        await db.delete(auth_session)
        await db.commit()


async def get_session_user(request: HTTPConnection, db: AsyncSession) -> User | None:
    raw_session_id = request.session.get(AUTH_SESSION_ID_KEY)
    if not raw_session_id:
        return None
    try:
        session_id = UUID(raw_session_id)
    except ValueError:
        request.session.pop(AUTH_SESSION_ID_KEY, None)
        return None
    result = await db.execute(
        select(AuthSession)
        .options(selectinload(AuthSession.user))
        .where(AuthSession.id == session_id)
    )
    auth_session = result.scalar_one_or_none()
    if auth_session is None or auth_session.user is None:
        request.session.pop(AUTH_SESSION_ID_KEY, None)
        return None
    now = _now_utc()
    if not _auth_session_is_valid(auth_session, now):
        await db.delete(auth_session)
        await db.commit()
        request.session.pop(AUTH_SESSION_ID_KEY, None)
        return None
    auth_session.last_seen_at = now
    await db.commit()
    return auth_session.user if auth_session.user.is_active else None
