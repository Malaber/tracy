"""Explicit server-side administrator bootstrap; never exposed as a public endpoint."""

import asyncio
import sys

from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models import User


async def set_admin(email: str, *, revoke: bool = False):
    async with AsyncSessionLocal() as db:
        user = await db.scalar(select(User).where(User.email == email.strip().lower()))
        if user is None or not user.is_active:
            raise ValueError(
                "Register an active account with this email before granting admin access"
            )
        user.is_admin = not revoke
        await db.commit()


if __name__ == "__main__":
    asyncio.run(set_admin(sys.argv[1], revoke="--revoke" in sys.argv[2:]))
