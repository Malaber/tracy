from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.models import AuthSession, User
from app.services.auth_sessions import _auth_session_is_valid, _now_utc, get_session_user


oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/login/verify", auto_error=False)


async def get_current_user(
    request: Request,
    db: AsyncSession = Depends(get_db),
    token: str | None = Depends(oauth2_scheme),
) -> User:
    if not token:
        session_user = await get_session_user(request, db)
        if session_user is not None:
            return session_user
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
        user_id = UUID(payload["sub"])
        session_id = UUID(payload["sid"]) if "sid" in payload else None
    except (JWTError, KeyError, TypeError, ValueError) as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from exc
    result = await db.execute(select(User).where(User.id == user_id, User.is_active.is_(True)))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    if session_id is not None:
        session = await db.get(AuthSession, session_id)
        now = _now_utc()
        if (
            session is None
            or session.user_id != user.id
            or not _auth_session_is_valid(session, now)
        ):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
        session.last_seen_at = now
        await db.commit()
    return user
