import hashlib
import secrets
from datetime import UTC, datetime, timedelta
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import PasskeyAddLink, User


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def active_link_query(token: str):
    return select(PasskeyAddLink).where(
        PasskeyAddLink.token_hash == token_hash(token),
        PasskeyAddLink.expires_at > datetime.now(UTC),
        PasskeyAddLink.used_at.is_(None),
        PasskeyAddLink.revoked_at.is_(None),
        PasskeyAddLink.user_id.in_(select(User.id).where(User.is_active.is_(True))),
    )


async def issue_link(db: AsyncSession, user: User, *, admin_id: UUID, hours: int):
    if not user.is_active:
        raise ValueError("Cannot issue a link for an inactive account")
    if not 1 <= hours <= 720:
        raise ValueError("Choose an expiry between 1 and 720 hours (30 days)")
    token = secrets.token_urlsafe(32)
    link = PasskeyAddLink(
        user_id=user.id,
        created_by=admin_id,
        token_hash=token_hash(token),
        expires_at=datetime.now(UTC) + timedelta(hours=hours),
    )
    db.add(link)
    await db.commit()
    await db.refresh(link)
    return token, link
