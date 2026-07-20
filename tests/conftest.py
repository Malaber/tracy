from collections.abc import AsyncGenerator
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.api.deps import get_current_user
from app.core.database import Base, get_db
from app.main import create_app
from app.models import User


@pytest.fixture
async def client(tmp_path) -> AsyncGenerator[AsyncClient, None]:
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)

    async def override_db():
        async with session_factory() as session:
            yield session

    user = User(
        id=uuid4(),
        email="tracy-test@example.com",
        display_name="Tracy Test",
    )
    async with session_factory() as session:
        session.add(user)
        await session.commit()

    async def override_current_user():
        return user

    application = create_app(with_lifespan=False)
    application.dependency_overrides[get_db] = override_db
    application.dependency_overrides[get_current_user] = override_current_user
    async with AsyncClient(
        transport=ASGITransport(app=application), base_url="http://test"
    ) as test_client:
        yield test_client
    await engine.dispose()


@pytest.fixture
async def unauthenticated_client(tmp_path) -> AsyncGenerator[AsyncClient, None]:
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'unauthenticated.db'}")
    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)

    async def override_db():
        async with session_factory() as session:
            yield session

    application = create_app(with_lifespan=False)
    application.dependency_overrides[get_db] = override_db
    async with AsyncClient(
        transport=ASGITransport(app=application), base_url="http://test"
    ) as test_client:
        yield test_client
    await engine.dispose()
