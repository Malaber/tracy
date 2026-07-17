from sqlalchemy import Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class Preferences(Base):
    __tablename__ = "preferences"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, default=1)
    federal_state: Mapped[str] = mapped_column(String(2), nullable=False, default="DE")
    daily_target_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=480)
    rounding_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=15)
