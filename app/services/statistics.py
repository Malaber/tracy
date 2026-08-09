from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta
from typing import Any

from app.services.german_holidays import holidays_between, is_workday


def period_bounds(period: str, anchor: date) -> tuple[date, date]:
    if period == "week":
        start = anchor - timedelta(days=anchor.weekday())
        return start, start + timedelta(days=6)
    if period == "month":
        start = anchor.replace(day=1)
        next_month = (
            start.replace(year=start.year + 1, month=1)
            if start.month == 12
            else start.replace(month=start.month + 1)
        )
        return start, next_month - timedelta(days=1)
    if period == "year":
        return date(anchor.year, 1, 1), date(anchor.year, 12, 31)
    raise ValueError("Period must be week, month, or year.")


def build_statistics(
    start: date,
    end: date,
    entry_by_date: dict[date, dict[str, Any]],
    *,
    federal_state: str,
    daily_target_minutes: int,
    day_off_dates: set[date] | None = None,
) -> dict[str, Any]:
    if end < start:
        raise ValueError("End date must be on or after start date.")
    if (end - start).days > 732:
        raise ValueError("Statistics ranges are limited to two years.")

    holidays = holidays_between(start, end, federal_state)
    day_off_dates = day_off_dates or set()
    days: list[dict[str, Any]] = []
    weekly: dict[date, dict[str, int]] = defaultdict(
        lambda: {"exact_minutes": 0, "billable_minutes": 0, "target_minutes": 0}
    )
    total_exact = 0
    total_billable = 0
    target_minutes = 0
    completed_days = 0
    calendar_days = 0
    weekend_days = 0
    holiday_workdays = 0
    day_off_workdays = 0

    current = start
    while current <= end:
        calendar_days += 1
        weekend = current.weekday() >= 5
        holiday = holidays.get(current)
        baseline_workday = is_workday(current, holidays)
        day_off = current in day_off_dates
        workday = baseline_workday and not day_off
        if weekend:
            weekend_days += 1
        if holiday and not weekend:
            holiday_workdays += 1
        if day_off and baseline_workday:
            day_off_workdays += 1
        expected = daily_target_minutes if workday else 0
        target_minutes += expected

        entry = entry_by_date.get(current, {})
        exact = entry.get("exact_minutes") or 0
        billable = entry.get("billable_minutes") or 0
        if entry.get("status") == "complete":
            completed_days += 1
        total_exact += exact
        total_billable += billable

        week_start = current - timedelta(days=current.weekday())
        weekly[week_start]["exact_minutes"] += exact
        weekly[week_start]["billable_minutes"] += billable
        weekly[week_start]["target_minutes"] += expected
        days.append(
            {
                "date": current.isoformat(),
                "weekday": current.strftime("%A"),
                "is_weekend": weekend,
                "holiday": holiday,
                "is_day_off": day_off,
                "is_workday": workday,
                "expected_minutes": expected,
                "exact_minutes": exact,
                "billable_minutes": billable,
                "balance_minutes": exact - expected,
                "status": entry.get("status", "empty"),
                "notes": entry.get("notes", ""),
            }
        )
        current += timedelta(days=1)

    expected_workdays = sum(1 for day in days if day["is_workday"])
    return {
        "start": start.isoformat(),
        "end": end.isoformat(),
        "summary": {
            "calendar_days": calendar_days,
            "expected_workdays": expected_workdays,
            "weekend_days": weekend_days,
            "holiday_workdays": holiday_workdays,
            "day_off_workdays": day_off_workdays,
            "completed_days": completed_days,
            "exact_minutes": total_exact,
            "billable_minutes": total_billable,
            "target_minutes": target_minutes,
            "balance_minutes": total_exact - target_minutes,
            "completion_percent": (
                round(total_exact / target_minutes * 100, 1) if target_minutes else 0
            ),
            "average_minutes": round(total_exact / completed_days) if completed_days else 0,
        },
        "weeks": [
            {"week_start": week.isoformat(), **values} for week, values in sorted(weekly.items())
        ],
        "days": days,
    }
