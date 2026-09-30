"""Browser passkey sign-in for native clients, with an S256 PKCE code exchange."""

import base64
import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import RedirectResponse
from jose import JWTError, jwt
from pydantic import BaseModel, Field
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user, oauth2_scheme
from app.core.config import settings
from app.core.database import get_db
from app.core.security import create_access_token
from app.models import AuthSession, User
from app.models.mobile_authorization import MobileAuthorization
from app.services.auth_sessions import get_session_user

router = APIRouter(prefix="/auth/mobile")


@router.get("/authorize")
async def authorize(
    request: Request,
    state: str = Query(pattern=r"^[A-Za-z0-9_-]{43,128}$"),
    code_challenge: str = Query(pattern=r"^[A-Za-z0-9_-]{43}$"),
    db: AsyncSession = Depends(get_db),
) -> Response:
    user = await get_session_user(request, db)
    if user is None:
        next_path = "/api/v1/auth/mobile/authorize?" + urlencode(
            {"state": state, "code_challenge": code_challenge}
        )
        return RedirectResponse("/login?" + urlencode({"next": next_path}), status_code=303)
    now = datetime.now(UTC)
    await db.execute(delete(MobileAuthorization).where(MobileAuthorization.expires_at <= now))
    code = secrets.token_urlsafe(32)
    db.add(
        MobileAuthorization(
            code_hash=hashlib.sha256(code.encode()).hexdigest(),
            user_id=user.id,
            challenge=code_challenge,
            expires_at=now + timedelta(minutes=2),
        )
    )
    await db.commit()
    # The callback is fixed; neither arbitrary redirects nor access tokens enter the URL.
    return RedirectResponse(
        "de.malaber.tracy://auth?" + urlencode({"code": code, "state": state}),
        status_code=303,
        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"},
    )


class ExchangePayload(BaseModel):
    code: str = Field(pattern=r"^[A-Za-z0-9_-]{43}$")
    code_verifier: str = Field(pattern=r"^[A-Za-z0-9._~-]{43,128}$")


@router.post("/token")
async def exchange(
    payload: ExchangePayload, response: Response, db: AsyncSession = Depends(get_db)
) -> dict:
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(payload.code_verifier.encode()).digest())
        .decode()
        .rstrip("=")
    )
    now = datetime.now(UTC)
    # DELETE RETURNING consumes the code atomically, including across server workers.
    user_id = (
        await db.execute(
            delete(MobileAuthorization)
            .where(
                MobileAuthorization.code_hash == hashlib.sha256(payload.code.encode()).hexdigest(),
                MobileAuthorization.challenge == challenge,
                MobileAuthorization.expires_at > now,
            )
            .returning(MobileAuthorization.user_id)
        )
    ).scalar_one_or_none()
    user = await db.get(User, user_id) if user_id else None
    if user is None or not user.is_active:
        await db.commit()
        raise HTTPException(401, "Sign-in expired. Please sign in again.")
    session = AuthSession(
        user_id=user.id,
        last_seen_at=now,
        expires_at=now + timedelta(minutes=settings.access_token_expire_minutes),
    )
    db.add(session)
    await db.commit()
    await db.refresh(session)
    response.headers["Cache-Control"] = "no-store"
    return {
        "access_token": create_access_token(user.id, session_id=session.id),
        "token_type": "bearer",
        "user_id": str(user.id),
    }


@router.post("/logout", status_code=204)
async def logout(
    user: User = Depends(get_current_user),
    token: str | None = Depends(oauth2_scheme),
    db: AsyncSession = Depends(get_db),
) -> Response:
    try:
        payload = jwt.decode(token or "", settings.secret_key, algorithms=[settings.algorithm])
        session_id = UUID(payload["sid"])
    except (JWTError, KeyError, ValueError, TypeError) as exc:
        raise HTTPException(401) from exc
    await db.execute(
        delete(AuthSession).where(AuthSession.id == session_id, AuthSession.user_id == user.id)
    )
    await db.commit()
    return Response(status_code=204)
