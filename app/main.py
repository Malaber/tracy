import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from app.api.v1.routes import router as api_router
from app.core.config import settings
from app.core.database import run_migrations
from app.web.routes import router as web_router


logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI):
    logger.info("Running database migrations")
    await run_migrations()
    yield


def create_app(*, with_lifespan: bool = True) -> FastAPI:
    application = FastAPI(
        title=settings.app_name,
        lifespan=lifespan if with_lifespan else None,
    )
    application.include_router(api_router, prefix="/api/v1")
    application.include_router(web_router)
    application.mount("/static", StaticFiles(directory="app/web/static"), name="static")

    @application.get("/health")
    async def health() -> JSONResponse:
        return JSONResponse({"status": "ok"})

    return application


app = create_app()
