from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates
from fastpasskey import install_fastpasskey_templates
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.models import User
from app.services.auth_sessions import get_session_user, revoke_auth_session


router = APIRouter()
templates = Jinja2Templates(directory="app/web/templates")
install_fastpasskey_templates(templates.env)

TRANSLATIONS = {
    "auth.login.title": "Your working time, protected by a passkey",
    "auth.login.intro": "Sign in securely without a password, or create your Tracy account.",
    "auth.login.capabilities_link": "How passkeys work",
    "auth.login.sign_in_title": "Welcome back",
    "auth.login.sign_in_body": "Use a passkey saved on this device or in your password manager.",
    "auth.login.sign_in_button": "Sign in with passkey",
    "auth.login.create_account_title": "Create your account",
    "auth.login.create_account_body": "Your passkey protects your private work records.",
    "auth.login.display_name": "Display name",
    "auth.login.email": "Email address",
    "auth.login.create_passkey_button": "Create passkey",
    "auth.login.tabs_aria": "Authentication options",
    "auth.login.sign_in_tab": "Sign in",
    "auth.login.create_account_tab": "Create account",
    "settings.security": "Security",
    "settings.your_passkeys": "Your passkeys",
    "settings.add_another": "Add another",
    "settings.helper": "Name, add, rename, or remove passkeys connected to your account.",
    "settings.name_this_passkey": "Name this passkey",
    "settings.passkey_name_placeholder": "For example: Work laptop",
    "settings.no_passkeys_title": "No passkeys",
    "settings.no_passkeys_body": "Add a passkey to keep access to your account.",
    "settings.confirm_deletion": "Confirm deletion",
    "settings.delete_this_passkey": "Delete this passkey?",
    "settings.delete_help_generic": "Confirm with another passkey before deletion.",
    "settings.continue_to_verification": "Continue to verification",
    "common.continue": "Continue",
    "common.cancel": "Cancel",
    "common.close": "Close",
}


def _translate(key: str, **values: object) -> str:
    return TRANSLATIONS.get(key, key).format(**values)


def _context(request: Request, user: User | None = None, **values: object) -> dict:
    return {
        "request": request,
        "app_name": settings.app_name,
        "user": user,
        "t": _translate,
        **values,
    }


def _safe_next_path(request: Request) -> str:
    candidate = request.query_params.get("next", "/")
    return candidate if candidate.startswith("/") and not candidate.startswith("//") else "/"


@router.get("/login", response_class=HTMLResponse, response_model=None)
async def login(request: Request, db: AsyncSession = Depends(get_db)) -> Response:
    next_path = _safe_next_path(request)
    user = await get_session_user(request, db)
    if user is not None:
        return RedirectResponse(next_path, status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="login.html",
        context=_context(request, next_url=next_path),
    )


@router.get("/", response_class=HTMLResponse)
async def index(request: Request, db: AsyncSession = Depends(get_db)) -> Response:
    user = await get_session_user(request, db)
    if user is None:
        return RedirectResponse("/login", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context=_context(request, user),
    )


@router.get("/security", response_class=HTMLResponse, response_model=None)
async def security(request: Request, db: AsyncSession = Depends(get_db)) -> Response:
    user = await get_session_user(request, db)
    if user is None:
        return RedirectResponse("/login?next=/security", status_code=303)
    return templates.TemplateResponse(
        request=request,
        name="security.html",
        context=_context(request, user),
    )


@router.get("/capabilities", response_class=HTMLResponse)
async def capabilities(request: Request) -> Response:
    return templates.TemplateResponse(
        request=request,
        name="capabilities.html",
        context=_context(request),
    )


@router.post("/logout")
async def logout(request: Request, db: AsyncSession = Depends(get_db)) -> RedirectResponse:
    await revoke_auth_session(request, db)
    request.session.clear()
    return RedirectResponse("/login", status_code=303)
