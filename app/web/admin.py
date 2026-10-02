import secrets
from datetime import UTC, datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, EmailStr, Field, ValidationError
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.config import settings
from app.core.database import get_db
from app.models import PasskeyAddLink, Preferences, User
from app.services.auth_sessions import get_session_user
from app.services.passkey_links import issue_link
from app.web.routes import _context, templates

router = APIRouter(prefix="/admin", include_in_schema=False)


async def admin_user(request: Request, db: AsyncSession = Depends(get_db)) -> User:
    user = await get_session_user(request, db)
    if user is None:
        raise HTTPException(303, headers={"Location": "/login?next=/admin"})
    if not user.is_admin:
        raise HTTPException(403, "Administrator access required")
    return user


def csrf_token(request: Request) -> str:
    if "admin_csrf" not in request.session:
        request.session["admin_csrf"] = secrets.token_urlsafe(32)
    return request.session["admin_csrf"]


async def checked_form(request: Request):
    form = await request.form()
    expected = request.session.get("admin_csrf", "")
    supplied = form.get("csrf", "")
    if (
        not expected
        or not isinstance(supplied, str)
        or not secrets.compare_digest(expected.encode(), supplied.encode())
    ):
        raise HTTPException(403, "Invalid form token. Reload the admin page and try again.")
    return form


async def render_admin(request, db, admin, *, error=None, link_url=None, status_code=200):
    await db.refresh(admin)
    users = (
        await db.scalars(select(User).options(selectinload(User.passkeys)).order_by(User.email))
    ).all()
    links = (
        await db.scalars(select(PasskeyAddLink).order_by(PasskeyAddLink.created_at.desc()))
    ).all()
    return templates.TemplateResponse(
        request=request,
        name="admin.html",
        context=_context(
            request,
            admin,
            users=users,
            issuers={account.id: account.email for account in users},
            links=links,
            csrf=csrf_token(request),
            error=error,
            link_url=link_url,
            now=datetime.now(UTC).replace(tzinfo=None),
        ),
        status_code=status_code,
        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"},
    )


@router.get("")
async def index(
    request: Request, admin: User = Depends(admin_user), db: AsyncSession = Depends(get_db)
):
    return await render_admin(request, db, admin)


class NewUser(BaseModel):
    email: EmailStr
    display_name: str = Field(min_length=1, max_length=120)


@router.post("/users")
async def create_user(
    request: Request, admin: User = Depends(admin_user), db: AsyncSession = Depends(get_db)
):
    form = await checked_form(request)
    try:
        values = NewUser(
            email=str(form.get("email", "")).strip(),
            display_name=str(form.get("display_name", "")).strip(),
        )
    except ValidationError:
        return await render_admin(
            request,
            db,
            admin,
            error="Enter a valid email and display name (up to 120 characters).",
            status_code=400,
        )
    user = User(email=str(values.email).lower(), display_name=values.display_name, is_admin=False)
    db.add(user)
    try:
        await db.flush()
        db.add(Preferences(user_id=user.id))
        await db.commit()
    except IntegrityError:
        await db.rollback()
        return await render_admin(
            request, db, admin, error="An account with that email already exists.", status_code=409
        )
    return RedirectResponse("/admin", status_code=303)


@router.post("/users/{user_id}/links")
async def generate_link(
    user_id: UUID,
    request: Request,
    admin: User = Depends(admin_user),
    db: AsyncSession = Depends(get_db),
):
    form = await checked_form(request)
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(404)
    try:
        hours = int(str(form.get("hours", "")))
        token, _ = await issue_link(db, user, admin_id=admin.id, hours=hours)
    except ValueError as exc:
        return await render_admin(request, db, admin, error=str(exc), status_code=400)
    origin = settings.app_base_url or str(request.base_url).rstrip("/")
    return await render_admin(request, db, admin, link_url=f"{origin}/passkey-add/{token}")


@router.post("/links/{link_id}/revoke")
async def revoke_link(
    link_id: UUID,
    request: Request,
    admin: User = Depends(admin_user),
    db: AsyncSession = Depends(get_db),
):
    await checked_form(request)
    await db.execute(
        update(PasskeyAddLink)
        .where(
            PasskeyAddLink.id == link_id,
            PasskeyAddLink.used_at.is_(None),
            PasskeyAddLink.revoked_at.is_(None),
        )
        .values(revoked_at=datetime.now(UTC))
    )
    await db.commit()
    return RedirectResponse("/admin", status_code=303)
