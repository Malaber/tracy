"""SQLAdmin frontend with Tracy's existing passkey sessions and enrollment service."""

import secrets
from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field
from sqladmin import Admin, ModelView, expose
from sqladmin.authentication import AuthenticationBackend, login_required
from sqlalchemy import or_, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import async_sessionmaker
from starlette.exceptions import HTTPException
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import RedirectResponse, Response

from app.core.config import settings
from app.core.database import engine
from app.models import PasskeyAddLink, Preferences, User
from app.services.auth_sessions import get_session_user
from app.services.passkey_links import issue_link
from app.web.routes import templates, _context


class AdminHeaders(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response


class SessionAdminAuth(AuthenticationBackend):
    def __init__(self, session_maker):
        # Reuse the outer SessionMiddleware, including secure cookie/expiry settings.
        self.middlewares = []
        self.session_maker = session_maker

    async def login(self, request):
        return RedirectResponse("/login?next=/admin/user/list", status_code=303)

    async def logout(self, request):
        # Confirm via Tracy's POST logout; a GET must not mutate the session.
        return templates.TemplateResponse(
            request=request, name="admin_signout.html", context=_context(request)
        )

    async def authenticate(self, request):
        async with self.session_maker() as db:
            user = await get_session_user(request, db)
        if user is None:
            return await self.login(request)
        if not user.is_admin:
            return Response("Administrator access required", status_code=403)
        request.state.admin_id = user.id
        if request.method not in {"GET", "HEAD", "OPTIONS"}:
            form = await request.form()
            expected, supplied = request.session.get("admin_csrf", ""), form.get("csrf", "")
            if (
                not expected
                or not isinstance(supplied, str)
                or not secrets.compare_digest(expected.encode(), supplied.encode())
            ):
                return Response("Invalid form token. Reload the admin page.", status_code=403)
        request.session.setdefault("admin_csrf", secrets.token_urlsafe(32))
        return True


class TracyAdmin(Admin):
    @login_required
    async def index(self, request):
        return RedirectResponse(request.url_for("admin:list", identity="user"), status_code=303)


class NewUser(BaseModel):
    email: EmailStr
    display_name: str = Field(min_length=1, max_length=120)


class UserAdmin(ModelView, model=User):
    name, name_plural = "Account", "Accounts"
    column_list = [User.email, User.display_name, User.is_admin, User.is_active, User.created_at]
    column_details_list = [User.id, *column_list]
    column_labels = {
        User.id: "Account ID",
        User.email: "Email",
        User.display_name: "Display name",
        User.is_admin: "Administrator",
        User.is_active: "Active",
        User.created_at: "Created (UTC)",
    }
    column_searchable_list = [User.email, User.display_name]
    column_sortable_list = column_list
    column_default_sort = [(User.email, False), (User.id, False)]
    form_columns = [User.email, User.display_name]
    form_args = {"display_name": {"label": "Display Name"}}
    page_size = 25
    page_size_options = [25, 50, 100]
    can_edit = can_delete = can_export = False
    create_template = "tracy_admin/create.html"
    details_template = "tracy_admin/user_details.html"

    async def insert_model(self, request, data):
        values = NewUser(email=data["email"].strip(), display_name=data["display_name"].strip())
        user = User(
            email=str(values.email).lower(), display_name=values.display_name, is_admin=False
        )
        async with self.session_maker(expire_on_commit=False) as db:
            db.add(user)
            try:
                await db.flush()
                db.add(Preferences(user_id=user.id))
                await db.commit()
            except IntegrityError as exc:
                await db.rollback()
                raise ValueError("An account with that email already exists.") from exc
        return user

    @expose("/{pk}/passkey-add-link", methods=["POST"])
    async def generate_link(self, request):
        try:
            user_id = UUID(request.path_params["pk"])
        except ValueError as exc:
            raise HTTPException(404) from exc
        form = await request.form()
        async with self.session_maker(expire_on_commit=False) as db:
            user = await db.get(User, user_id)
            if user is None:
                raise HTTPException(404)
            error, link_url = None, None
            try:
                token, link = await issue_link(
                    db, user, admin_id=request.state.admin_id, hours=int(str(form.get("hours", "")))
                )
                origin = settings.app_base_url or str(request.base_url).rstrip("/")
                link_url = f"{origin}/passkey-add/{token}#identifier={link.id}"
            except ValueError as exc:
                error = str(exc)
        return await self.templates.TemplateResponse(
            request,
            self.details_template,
            {"model_view": self, "model": user, "link_url": link_url, "error": error},
            status_code=400 if error else 200,
        )


class LinkAdmin(ModelView, model=PasskeyAddLink):
    name, name_plural = "Passkey link", "Passkey links"
    column_list = [
        PasskeyAddLink.id,
        PasskeyAddLink.user_id,
        PasskeyAddLink.created_by,
        PasskeyAddLink.created_at,
        PasskeyAddLink.expires_at,
        PasskeyAddLink.used_at,
        PasskeyAddLink.revoked_at,
    ]
    column_details_list = column_list
    column_searchable_list = [PasskeyAddLink.id, PasskeyAddLink.user_id]
    column_sortable_list = column_list
    column_default_sort = [(PasskeyAddLink.created_at, True), (PasskeyAddLink.id, False)]
    column_labels = {
        PasskeyAddLink.id: "Link identifier",
        PasskeyAddLink.user_id: "Account ID",
        PasskeyAddLink.created_by: "Issued by (account ID)",
        PasskeyAddLink.created_at: "Created (UTC)",
        PasskeyAddLink.expires_at: "Expires (UTC)",
        PasskeyAddLink.used_at: "Used (UTC)",
        PasskeyAddLink.revoked_at: "Revoked (UTC)",
    }
    page_size = 25
    page_size_options = [25, 50, 100]
    can_create = can_edit = can_delete = can_export = False
    details_template = "tracy_admin/link_details.html"

    def search_query(self, stmt, term):
        # SQLite stores UUIDs without hyphens; compare typed IDs rather than their
        # dialect-specific string representation when pasting a full identifier.
        try:
            identifier = UUID(term)
        except ValueError:
            return super().search_query(stmt, term)
        return stmt.where(
            or_(PasskeyAddLink.id == identifier, PasskeyAddLink.user_id == identifier)
        )

    @expose("/{pk}/revoke", methods=["POST"])
    async def revoke_link(self, request):
        try:
            link_id = UUID(request.path_params["pk"])
        except ValueError as exc:
            raise HTTPException(404) from exc
        async with self.session_maker() as db:
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
        return RedirectResponse(
            request.url_for("admin:details", identity=self.identity, pk=link_id), status_code=303
        )


def configure_admin(app, session_maker=None):
    factory = session_maker or async_sessionmaker(engine, expire_on_commit=False)
    admin = TracyAdmin(
        app,
        session_maker=factory,
        title="Tracy administration",
        authentication_backend=SessionAdminAuth(factory),
        templates_dir="app/admin_templates",
        middlewares=[Middleware(AdminHeaders)],
    )
    admin.add_view(UserAdmin)
    admin.add_view(LinkAdmin)
    return admin
