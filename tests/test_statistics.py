from datetime import date

import pytest

from app.services.statistics import build_statistics, period_bounds


def test_period_bounds():
    assert period_bounds("week", date(2026, 7, 18)) == (date(2026, 7, 13), date(2026, 7, 19))
    assert period_bounds("month", date(2026, 12, 18)) == (
        date(2026, 12, 1),
        date(2026, 12, 31),
    )
    assert period_bounds("year", date(2026, 7, 18)) == (
        date(2026, 1, 1),
        date(2026, 12, 31),
    )
    with pytest.raises(ValueError):
        period_bounds("quarter", date(2026, 7, 18))


def test_statistics_include_weekend_holiday_and_saved_time():
    entries = {
        date(2026, 12, 24): {
            "status": "complete",
            "exact_minutes": 480,
            "billable_minutes": 480,
            "notes": "Customer A",
        },
        date(2026, 12, 26): {
            "status": "complete",
            "exact_minutes": 60,
            "billable_minutes": 60,
            "notes": "Emergency",
        },
    }
    result = build_statistics(
        date(2026, 12, 24),
        date(2026, 12, 28),
        entries,
        federal_state="DE",
        daily_target_minutes=480,
        day_off_dates={date(2026, 12, 25), date(2026, 12, 26)},
    )
    assert result["summary"] == {
        "calendar_days": 5,
        "expected_workdays": 2,
        "weekend_days": 2,
        "holiday_workdays": 1,
        "day_off_workdays": 0,
        "completed_days": 2,
        "exact_minutes": 540,
        "billable_minutes": 540,
        "target_minutes": 960,
        "balance_minutes": -420,
        "completion_percent": 56.2,
        "average_minutes": 270,
    }
    assert len(result["weeks"]) == 2
    assert result["days"][1]["holiday"] == "Christmas Day"
    assert result["days"][1]["is_day_off"] is True
    assert result["days"][0]["notes"] == "Customer A"


def test_statistics_days_off_reduce_only_required_workdays():
    result = build_statistics(
        date(2026, 7, 13),
        date(2026, 7, 19),
        {
            date(2026, 7, 15): {
                "status": "complete",
                "exact_minutes": 120,
                "billable_minutes": 120,
            }
        },
        federal_state="DE",
        daily_target_minutes=480,
        day_off_dates={
            date(2026, 7, 14),
            date(2026, 7, 15),
            date(2026, 7, 18),
        },
    )

    assert result["summary"]["expected_workdays"] == 3
    assert result["summary"]["day_off_workdays"] == 2
    assert result["summary"]["target_minutes"] == 1440
    assert result["summary"]["balance_minutes"] == -1320
    assert result["weeks"][0]["target_minutes"] == 1440

    tuesday = result["days"][1]
    assert tuesday["is_day_off"] is True
    assert tuesday["is_workday"] is False
    assert tuesday["expected_minutes"] == 0

    worked_day_off = result["days"][2]
    assert worked_day_off["exact_minutes"] == 120
    assert worked_day_off["balance_minutes"] == 120

    weekend_day_off = result["days"][5]
    assert weekend_day_off["is_day_off"] is True
    assert weekend_day_off["is_weekend"] is True


def test_statistics_empty_target_and_invalid_ranges():
    result = build_statistics(
        date(2026, 7, 18),
        date(2026, 7, 19),
        {},
        federal_state="DE",
        daily_target_minutes=0,
    )
    assert result["summary"]["completion_percent"] == 0
    assert result["summary"]["average_minutes"] == 0
    with pytest.raises(ValueError):
        build_statistics(
            date(2026, 2, 1), date(2026, 1, 1), {}, federal_state="DE", daily_target_minutes=480
        )
    with pytest.raises(ValueError):
        build_statistics(
            date(2024, 1, 1), date(2027, 1, 5), {}, federal_state="DE", daily_target_minutes=480
        )
