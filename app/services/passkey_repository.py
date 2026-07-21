from datetime import UTC, datetime
from uuid import UUID

from fastapi import Depends, Request
from fastpasskey import PasskeyConflictError, PasskeyCredential
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.database import get_db
from app.core.security import create_access_token
from app.models import Passkey, Preferences, User, WorkEntry
from app.services.auth_sessions import create_auth_session, revoke_auth_session


def _new_passkey(*, user_id: UUID | None, name: str, credential: PasskeyCredential) -> Passkey:
    created_at = datetime.now(UTC)
    passkey = Passkey(
        name=name,
        credential_id=credential.credential_id,
        public_key=credential.public_key,
        sign_count=credential.sign_count,
        created_at=created_at,
        last_used_at=created_at,
    )
    if user_id is not None:
        passkey.user_id = user_id
    return passkey


class TracyPasskeyRepository:
    def __init__(self, db: AsyncSession) -> None:
        self.db = db

    async def user_by_email(self, email: str) -> User | None:
        result = await self.db.execute(
            select(User).options(selectinload(User.passkeys)).where(User.email == email)
        )
        return result.scalar_one_or_none()

    async def user_by_id(self, user_id: UUID) -> User | None:
        result = await self.db.execute(
            select(User)
            .options(selectinload(User.passkeys))
            .where(User.id == user_id)
            .execution_options(populate_existing=True)
        )
        return result.scalar_one_or_none()

    async def passkey_by_credential_id(self, credential_id: str) -> Passkey | None:
        result = await self.db.execute(
            select(Passkey)
            .options(selectinload(Passkey.user))
            .where(Passkey.credential_id == credential_id)
        )
        return result.scalar_one_or_none()

    async def register_user(
        self,
        *,
        user_id: UUID,
        email: str,
        display_name: str,
        passkey_name: str,
        credential: PasskeyCredential,
    ) -> User:
        user = User(id=user_id, email=email, display_name=display_name)
        user.passkeys.append(_new_passkey(user_id=None, name=passkey_name, credential=credential))
        self.db.add(user)
        try:
            await self.db.flush()
            legacy_preferences = (
                await self.db.execute(
                    select(Preferences).where(Preferences.user_id.is_(None)).limit(1)
                )
            ).scalar_one_or_none()
            if legacy_preferences is None:
                self.db.add(Preferences(user_id=user.id))
            else:
                legacy_preferences.user_id = user.id
            await self.db.execute(
                update(WorkEntry).where(WorkEntry.user_id.is_(None)).values(user_id=user.id)
            )
            await self.db.commit()
        except IntegrityError as exc:
            await self.db.rollback()
            raise PasskeyConflictError from exc
        return await self.user_by_id(user.id) or user

    async def replace_passkeys(
        self, *, user_id: UUID, passkey_name: str, credential: PasskeyCredential
    ) -> User:
        await self.db.execute(delete(Passkey).where(Passkey.user_id == user_id))
        self.db.add(_new_passkey(user_id=user_id, name=passkey_name, credential=credential))
        await self.db.commit()
        user = await self.user_by_id(user_id)
        if user is None:
            raise RuntimeError("Replaced passkeys for a missing user")
        return user

    async def add_passkey(
        self, *, user_id: UUID, name: str, credential: PasskeyCredential
    ) -> Passkey:
        passkey = _new_passkey(user_id=user_id, name=name, credential=credential)
        self.db.add(passkey)
        await self.db.commit()
        await self.db.refresh(passkey)
        return passkey

    async def record_passkey_use(self, passkey: Passkey, *, new_sign_count: int) -> None:
        passkey.sign_count = new_sign_count
        passkey.last_used_at = datetime.now(UTC)
        await self.db.commit()
        await self.db.refresh(passkey)

    async def rename_passkey(self, passkey: Passkey, *, name: str, new_sign_count: int) -> Passkey:
        passkey.name = name
        passkey.sign_count = new_sign_count
        passkey.last_used_at = datetime.now(UTC)
        await self.db.commit()
        await self.db.refresh(passkey)
        return passkey

    async def delete_passkey(
        self,
        *,
        user_id: UUID,
        passkey_id: UUID,
        confirming_passkey: Passkey,
        new_sign_count: int,
    ) -> None:
        confirming_passkey.sign_count = new_sign_count
        confirming_passkey.last_used_at = datetime.now(UTC)
        await self.db.flush()
        await self.db.execute(
            delete(Passkey).where(Passkey.id == passkey_id, Passkey.user_id == user_id)
        )
        await self.db.commit()

    async def authenticate(self, request: Request, user: User) -> User:
        await create_auth_session(request, self.db, user)
        return user

    async def logout(self, request: Request) -> None:
        await revoke_auth_session(request, self.db)

    def access_token(self, user: User) -> str:
        return create_access_token(user.id)


def get_passkey_repository(
    db: AsyncSession = Depends(get_db),
) -> TracyPasskeyRepository:
    return TracyPasskeyRepository(db)
