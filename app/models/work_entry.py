import uuid
from datetime import date, datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.sql import func

from app.core.database import Base


class WorkEntry(Base):
    __tablename__ = "work_entries"
    __table_args__ = (UniqueConstraint("user_id", "work_date", name="uq_work_entries_user_date"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    work_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    check_in_minutes: Mapped[int | None] = mapped_column(Integer)
    check_out_minutes: Mapped[int | None] = mapped_column(Integer)
    check_out_next_day: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    notes: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    breaks: Mapped[list["BreakEntry"]] = relationship(
        back_populates="work_entry",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="BreakEntry.position",
    )


class BreakEntry(Base):
    __tablename__ = "break_entries"
    __table_args__ = (CheckConstraint("mode IN ('duration', 'range')", name="ck_break_mode"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    work_entry_id: Mapped[int] = mapped_column(
        ForeignKey("work_entries.id", ondelete="CASCADE"), nullable=False, index=True
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    mode: Mapped[str] = mapped_column(String(16), nullable=False)
    duration_minutes: Mapped[int | None] = mapped_column(Integer)
    start_minutes: Mapped[int | None] = mapped_column(Integer)
    end_minutes: Mapped[int | None] = mapped_column(Integer)

    work_entry: Mapped[WorkEntry] = relationship(back_populates="breaks")
