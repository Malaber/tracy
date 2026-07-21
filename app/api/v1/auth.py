from datetime import timedelta

from fastpasskey import FastPasskey, PasskeyRouterConfig, create_passkey_router

from app.api.deps import get_current_user
from app.core.config import settings
from app.services.passkey_repository import get_passkey_repository


def _passkey_service() -> FastPasskey:
    return FastPasskey(
        rp_name=settings.app_name,
        rp_id=settings.webauthn_rp_id,
        origin=settings.app_base_url,
        flow_ttl=timedelta(seconds=settings.auth_flow_expire_seconds),
    )


router = create_passkey_router(
    PasskeyRouterConfig(
        service_factory=_passkey_service,
        repository_dependency=get_passkey_repository,
        current_user_dependency=get_current_user,
        enable_add_link_routes=False,
    )
)
