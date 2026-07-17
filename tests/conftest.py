from collections.abc import AsyncGenerator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.core.database import Base, get_db
from app.main import create_app


@pytest.fixture
async def client(tmp_path) -> AsyncGenerator[AsyncClient, None]:
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
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
