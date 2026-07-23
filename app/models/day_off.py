import uuid
from datetime import date

from sqlalchemy import Date, ForeignKey, Integer, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class DayOff(Base):
    __tablename__ = "days_off"
    __table_args__ = (UniqueConstraint("user_id", "day_off_date", name="uq_days_off_user_date"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    day_off_date: Mapped[date] = mapped_column(Date, nullable=False)
