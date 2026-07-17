from __future__ import annotations

import re
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any


TIME_PATTERN = re.compile(r"^(\d{1,2}):(\d{2})$")
DECIMAL_PATTERN = re.compile(r"^\d{1,2}(?:[.,]\d+)?$")


def parse_clock_time(value: str | None) -> int | None:
    """Parse 8, 8:30, 8.5, and 8,5 into minutes after midnight."""
    if value is None or not value.strip():
        return None

    normalized = value.strip()
    match = TIME_PATTERN.fullmatch(normalized)
    if match:
        hours, minutes = (int(part) for part in match.groups())
        if 0 <= hours <= 23 and 0 <= minutes <= 59:
            return hours * 60 + minutes
        raise ValueError("Time must be between 00:00 and 23:59.")

    if not DECIMAL_PATTERN.fullmatch(normalized):
        raise ValueError("Use a time such as 8, 8:30, or 8.5.")

    try:
        hours_decimal = Decimal(normalized.replace(",", "."))
    except InvalidOperation as exc:  # pragma: no cover - guarded by the regular expression.
        raise ValueError("Use a valid time.") from exc
    if not 0 <= hours_decimal < 24:
        raise ValueError("Time must be between 00:00 and 23:59.")
    minutes = int((hours_decimal * 60).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    if minutes >= 24 * 60:
        raise ValueError("Time must be between 00:00 and 23:59.")
    return minutes


def format_clock_time(minutes: int | None) -> str | None:
    if minutes is None:
        return None
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def round_up(minutes: int, increment: int) -> int:
    if increment <= 1:
        return minutes
    return ((minutes + increment - 1) // increment) * increment


def duration_for_range(start: int, end: int, *, crosses_midnight: bool = False) -> int:
    effective_end = end + (24 * 60 if crosses_midnight else 0)
    if effective_end <= start:
        raise ValueError("End time must be later than start time.")
    return effective_end - start


def calculate_break_minutes(breaks: list[dict[str, Any]]) -> int:
    total = 0
    for item in breaks:
        if item["mode"] == "duration":
            duration = item.get("duration_minutes")
            if not isinstance(duration, int) or duration <= 0:
                raise ValueError("Break durations must be positive whole minutes.")
            total += duration
            continue

        start = item.get("start_minutes")
        end = item.get("end_minutes")
        if not isinstance(start, int) or not isinstance(end, int):
            raise ValueError("Break ranges need both a start and an end time.")
        total += duration_for_range(start, end, crosses_midnight=end < start)
    return total


def calculate_work_minutes(
    check_in: int | None,
    check_out: int | None,
    check_out_next_day: bool,
    breaks: list[dict[str, Any]],
) -> tuple[int | None, int]:
    break_minutes = calculate_break_minutes(breaks)
    if check_in is None and check_out is None:
        if break_minutes:
            raise ValueError("Add a check-in and check-out before adding breaks.")
        return None, 0
    if check_in is None:
        raise ValueError("A check-out needs a check-in time.")
    if check_out is None:
        if break_minutes:
            raise ValueError("Complete the check-out before adding breaks.")
        return None, 0

    span = duration_for_range(check_in, check_out, crosses_midnight=check_out_next_day)
    if break_minutes >= span:
        raise ValueError("Breaks must be shorter than the total time span.")
    return span - break_minutes, break_minutes


def minutes_as_hours(minutes: int | None) -> float | None:
    if minutes is None:
        return None
    return round(minutes / 60, 2)
