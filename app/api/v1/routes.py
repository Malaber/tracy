from __future__ import annotations

import csv
import io
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.core.config import settings
from app.core.database import get_db
from app.models import BreakEntry, DayOff, Preferences, User, WorkEntry
from app.schemas.time_tracking import DayOffRangePayload, PreferencesPayload, WorkEntryPayload
from app.services.german_holidays import FEDERAL_STATES
from app.services.statistics import build_statistics, period_bounds
from app.services.time_calculation import (
    calculate_work_minutes,
    format_clock_time,
    minutes_as_hours,
    parse_clock_time,
    round_up,
)


router = APIRouter()


async def _preferences(db: AsyncSession, user_id: UUID) -> Preferences:
    preferences = (
        await db.execute(select(Preferences).where(Preferences.user_id == user_id))
    ).scalar_one_or_none()
    if preferences is None:
        preferences = Preferences(user_id=user_id)
        db.add(preferences)
        await db.flush()
    return preferences


def _preferences_payload(item: Preferences) -> dict:
    return {
        "federal_state": item.federal_state,
        "daily_target_minutes": item.daily_target_minutes,
        "rounding_minutes": item.rounding_minutes,
    }


def _validate_date_range(start: date, end: date) -> None:
    if end < start:
        raise HTTPException(status_code=422, detail="End date must be on or after start date.")
    if (end - start).days > 732:
        raise HTTPException(status_code=422, detail="Date range is limited to two years.")


async def _day_off_dates(db: AsyncSession, user_id: UUID, start: date, end: date) -> set[date]:
    result = await db.execute(
        select(DayOff.day_off_date)
        .where(
            DayOff.user_id == user_id,
            DayOff.day_off_date.between(start, end),
        )
        .order_by(DayOff.day_off_date)
    )
    return set(result.scalars().all())


def _days_off_payload(days_off: set[date]) -> dict:
    return {"days_off": [day.isoformat() for day in sorted(days_off)]}


def _break_to_payload(item: BreakEntry) -> dict:
    return {
        "id": item.id,
        "mode": item.mode,
        "duration_minutes": item.duration_minutes,
        "start": format_clock_time(item.start_minutes),
        "end": format_clock_time(item.end_minutes),
    }


def _entry_to_payload(
    entry: WorkEntry | None, work_date: date, rounding: int, *, is_day_off: bool = False
) -> dict:
    if entry is None:
        return {
            "saved": False,
            "date": work_date.isoformat(),
            "is_day_off": is_day_off,
            "check_in": None,
            "check_out": None,
            "check_out_next_day": False,
            "breaks": [],
            "break_minutes": 0,
            "exact_minutes": None,
            "exact_hours": None,
            "billable_minutes": None,
            "billable_hours": None,
            "status": "empty",
            "notes": "",
        }

    normalized_breaks = [
        {
            "mode": item.mode,
            "duration_minutes": item.duration_minutes,
            "start_minutes": item.start_minutes,
            "end_minutes": item.end_minutes,
        }
        for item in entry.breaks
    ]
    exact, break_minutes = calculate_work_minutes(
        entry.check_in_minutes,
        entry.check_out_minutes,
        entry.check_out_next_day,
        normalized_breaks,
    )
    billable = round_up(exact, rounding) if exact is not None else None
    status_name = "complete" if exact is not None else "in_progress"
    if entry.check_in_minutes is None:
        status_name = "empty"
    return {
        "saved": True,
        "date": entry.work_date.isoformat(),
        "is_day_off": is_day_off,
        "check_in": format_clock_time(entry.check_in_minutes),
        "check_out": format_clock_time(entry.check_out_minutes),
        "check_out_next_day": entry.check_out_next_day,
        "breaks": [_break_to_payload(item) for item in entry.breaks],
        "break_minutes": break_minutes,
        "exact_minutes": exact,
        "exact_hours": minutes_as_hours(exact),
        "billable_minutes": billable,
        "billable_hours": minutes_as_hours(billable),
        "status": status_name,
        "notes": entry.notes,
    }


async def _entry_for_date(db: AsyncSession, user_id: UUID, work_date: date) -> WorkEntry | None:
    result = await db.execute(
        select(WorkEntry).where(
            WorkEntry.user_id == user_id,
            WorkEntry.work_date == work_date,
        )
    )
    return result.scalar_one_or_none()


@router.get("/meta")
async def get_meta(_user: User = Depends(get_current_user)) -> dict:
    return {"federal_states": FEDERAL_STATES, "timezone": settings.timezone}


@router.get("/preferences")
async def get_preferences(
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    return _preferences_payload(await _preferences(db, user.id))


@router.put("/preferences")
async def update_preferences(
    payload: PreferencesPayload,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    item = await _preferences(db, user.id)
    item.federal_state = payload.federal_state
    item.daily_target_minutes = payload.daily_target_minutes
    item.rounding_minutes = payload.rounding_minutes
    await db.commit()
    return _preferences_payload(item)


@router.get("/days-off")
async def list_days_off(
    start: date,
    end: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    _validate_date_range(start, end)
    return _days_off_payload(await _day_off_dates(db, user.id, start, end))


@router.put("/days-off")
async def mark_days_off(
    payload: DayOffRangePayload,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    existing = await _day_off_dates(db, user.id, payload.start, payload.end)
    requested = [
        payload.start + timedelta(days=offset)
        for offset in range((payload.end - payload.start).days + 1)
    ]
    missing = [day for day in requested if day not in existing]
    if missing:
        db.add_all(DayOff(user_id=user.id, day_off_date=day) for day in missing)
        try:
            await db.commit()
        except IntegrityError:
            # An overlapping request may have inserted one of the same dates after our
            # initial read. Retry the remaining dates under savepoints so the PUT stays
            # idempotent without relying on database-specific conflict syntax.
            await db.rollback()
            existing = await _day_off_dates(db, user.id, payload.start, payload.end)
            for day in requested:
                if day in existing:
                    continue
                try:
                    async with db.begin_nested():
                        db.add(DayOff(user_id=user.id, day_off_date=day))
                        await db.flush()
                except IntegrityError:
                    pass
            await db.commit()
            recovered = await _day_off_dates(db, user.id, payload.start, payload.end)
            if not set(requested).issubset(recovered):
                raise
            return _days_off_payload(recovered)
    return _days_off_payload(await _day_off_dates(db, user.id, payload.start, payload.end))


@router.delete("/days-off", status_code=status.HTTP_204_NO_CONTENT)
async def clear_days_off(
    start: date,
    end: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> Response:
    _validate_date_range(start, end)
    await db.execute(
        delete(DayOff).where(
            DayOff.user_id == user.id,
            DayOff.day_off_date.between(start, end),
        )
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/entries")
async def list_entries(
    start: date,
    end: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> list[dict]:
    _validate_date_range(start, end)
    preferences = await _preferences(db, user.id)
    day_off_dates = await _day_off_dates(db, user.id, start, end)
    result = await db.execute(
        select(WorkEntry)
        .where(
            WorkEntry.user_id == user.id,
            WorkEntry.work_date.between(start, end),
        )
        .order_by(WorkEntry.work_date.desc())
    )
    return [
        _entry_to_payload(
            entry,
            entry.work_date,
            preferences.rounding_minutes,
            is_day_off=entry.work_date in day_off_dates,
        )
        for entry in result.scalars().all()
    ]


@router.get("/entries/{work_date}")
async def get_entry(
    work_date: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    preferences = await _preferences(db, user.id)
    entry = await _entry_for_date(db, user.id, work_date)
    day_off_dates = await _day_off_dates(db, user.id, work_date, work_date)
    return _entry_to_payload(
        entry,
        work_date,
        preferences.rounding_minutes,
        is_day_off=work_date in day_off_dates,
    )


@router.put("/entries/{work_date}")
async def upsert_entry(
    work_date: date,
    payload: WorkEntryPayload,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    entry = await _entry_for_date(db, user.id, work_date)
    if entry is None:
        entry = WorkEntry(user_id=user.id, work_date=work_date)
        db.add(entry)
    entry.check_in_minutes = parse_clock_time(payload.check_in)
    entry.check_out_minutes = parse_clock_time(payload.check_out)
    entry.check_out_next_day = payload.check_out_next_day
    entry.notes = payload.notes.strip()
    entry.breaks.clear()
    for position, break_payload in enumerate(payload.breaks):
        normalized = break_payload.normalized()
        entry.breaks.append(BreakEntry(position=position, **normalized))
    await db.commit()
    await db.refresh(entry)
    preferences = await _preferences(db, user.id)
    day_off_dates = await _day_off_dates(db, user.id, work_date, work_date)
    return _entry_to_payload(
        entry,
        work_date,
        preferences.rounding_minutes,
        is_day_off=work_date in day_off_dates,
    )


@router.delete("/entries/{work_date}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_entry(
    work_date: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> Response:
    entry = await _entry_for_date(db, user.id, work_date)
    if entry is not None:
        await db.delete(entry)
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/entries/{work_date}/check-in")
async def check_in(
    work_date: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    entry = await _entry_for_date(db, user.id, work_date)
    if entry is not None and entry.check_in_minutes is not None:
        raise HTTPException(status_code=409, detail="This day already has a check-in time.")
    now = datetime.now(ZoneInfo(settings.timezone))
    if entry is None:
        entry = WorkEntry(user_id=user.id, work_date=work_date)
        db.add(entry)
    entry.check_in_minutes = now.hour * 60 + now.minute
    await db.commit()
    await db.refresh(entry)
    preferences = await _preferences(db, user.id)
    day_off_dates = await _day_off_dates(db, user.id, work_date, work_date)
    return _entry_to_payload(
        entry,
        work_date,
        preferences.rounding_minutes,
        is_day_off=work_date in day_off_dates,
    )


@router.post("/entries/{work_date}/check-out")
async def check_out(
    work_date: date,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    entry = await _entry_for_date(db, user.id, work_date)
    if entry is None or entry.check_in_minutes is None:
        raise HTTPException(status_code=409, detail="Check in before checking out.")
    now = datetime.now(ZoneInfo(settings.timezone))
    checkout_minutes = now.hour * 60 + now.minute
    next_day = now.date() > work_date
    if not next_day and checkout_minutes <= entry.check_in_minutes:
        raise HTTPException(status_code=409, detail="Check-out must be later than check-in.")
    entry.check_out_minutes = checkout_minutes
    entry.check_out_next_day = next_day
    await db.commit()
    await db.refresh(entry)
    preferences = await _preferences(db, user.id)
    day_off_dates = await _day_off_dates(db, user.id, work_date, work_date)
    return _entry_to_payload(
        entry,
        work_date,
        preferences.rounding_minutes,
        is_day_off=work_date in day_off_dates,
    )


@router.get("/statistics")
async def get_statistics(
    period: str = Query(default="month", pattern="^(week|month|year|custom)$"),
    anchor: date = Query(default_factory=date.today),
    start: date | None = None,
    end: date | None = None,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> dict:
    if period == "custom":
        if start is None or end is None:
            raise HTTPException(status_code=422, detail="Custom statistics need start and end.")
        range_start, range_end = start, end
    else:
        range_start, range_end = period_bounds(period, anchor)
    if range_end < range_start or (range_end - range_start).days > 732:
        raise HTTPException(status_code=422, detail="Choose a valid range of up to two years.")

    preferences = await _preferences(db, user.id)
    day_off_dates = await _day_off_dates(db, user.id, range_start, range_end)
    result = await db.execute(
        select(WorkEntry).where(
            WorkEntry.user_id == user.id,
            WorkEntry.work_date.between(range_start, range_end),
        )
    )
    entries = {
        entry.work_date: _entry_to_payload(
            entry,
            entry.work_date,
            preferences.rounding_minutes,
            is_day_off=entry.work_date in day_off_dates,
        )
        for entry in result.scalars().all()
    }
    return build_statistics(
        range_start,
        range_end,
        entries,
        federal_state=preferences.federal_state,
        daily_target_minutes=preferences.daily_target_minutes,
        day_off_dates=day_off_dates,
    )


@router.get("/statistics/export.csv")
async def export_statistics(
    period: str = Query(default="month", pattern="^(week|month|year|custom)$"),
    anchor: date = Query(default_factory=date.today),
    start: date | None = None,
    end: date | None = None,
    db: AsyncSession = Depends(get_db),
    user: User = Depends(get_current_user),
) -> Response:
    data = await get_statistics(period, anchor, start, end, db, user)
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(
        [
            "Date",
            "Day",
            "Calendar",
            "Exact hours",
            "Billable hours",
            "Target hours",
            "Balance hours",
            "Notes",
        ]
    )
    for day in data["days"]:
        calendar_parts = ["Day off"] if day["is_day_off"] else []
        if day["holiday"]:
            calendar_parts.append(day["holiday"])
        elif day["is_weekend"]:
            calendar_parts.append("Weekend")
        elif not day["is_day_off"]:
            calendar_parts.append("Working day")
        calendar = "; ".join(calendar_parts)
        writer.writerow(
            [
                day["date"],
                day["weekday"],
                calendar,
                f"{day['exact_minutes'] / 60:.2f}",
                f"{day['billable_minutes'] / 60:.2f}",
                f"{day['expected_minutes'] / 60:.2f}",
                f"{day['balance_minutes'] / 60:.2f}",
                day["notes"],
            ]
        )
    filename = f"tracy-{data['start']}-{data['end']}.csv"
    return Response(
        content=output.getvalue(),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
