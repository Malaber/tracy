import pytest

from app.services.time_calculation import (
    calculate_break_minutes,
    calculate_work_minutes,
    duration_for_range,
    format_clock_time,
    minutes_as_hours,
    parse_clock_time,
    round_up,
)


@pytest.mark.parametrize(
    ("value", "expected"),
    [(None, None), ("", None), ("8", 480), ("08:30", 510), ("8,5", 510), ("8.25", 495)],
)
def test_parse_supported_clock_formats(value, expected):
    assert parse_clock_time(value) == expected


@pytest.mark.parametrize("value", ["24:00", "12:60", "hello", "24", "23.999"])
def test_reject_invalid_clock_formats(value):
    with pytest.raises(ValueError):
        parse_clock_time(value)


def test_duration_formatting_and_rounding():
    assert format_clock_time(None) is None
    assert format_clock_time(485) == "08:05"
    assert round_up(481, 15) == 495
    assert round_up(481, 1) == 481
    assert minutes_as_hours(None) is None
    assert minutes_as_hours(485) == 8.08
    assert duration_for_range(1380, 60, crosses_midnight=True) == 120
    with pytest.raises(ValueError):
        duration_for_range(600, 600)


def test_calculate_complete_workday_with_both_break_types():
    breaks = [
        {"mode": "duration", "duration_minutes": 15},
        {"mode": "range", "start_minutes": 720, "end_minutes": 750},
    ]
    assert calculate_break_minutes(breaks) == 45
    assert calculate_work_minutes(480, 1020, False, breaks) == (495, 45)


def test_calculate_overnight_break_and_incomplete_entries():
    breaks = [{"mode": "range", "start_minutes": 1410, "end_minutes": 15}]
    assert calculate_break_minutes(breaks) == 45
    assert calculate_work_minutes(None, None, False, []) == (None, 0)
    assert calculate_work_minutes(480, None, False, []) == (None, 0)


@pytest.mark.parametrize(
    "arguments",
    [
        (None, None, False, [{"mode": "duration", "duration_minutes": 10}]),
        (None, 600, False, []),
        (480, None, False, [{"mode": "duration", "duration_minutes": 10}]),
        (480, 500, False, [{"mode": "duration", "duration_minutes": 20}]),
    ],
)
def test_reject_invalid_workday_combinations(arguments):
    with pytest.raises(ValueError):
        calculate_work_minutes(*arguments)


@pytest.mark.parametrize(
    "breaks",
    [
        [{"mode": "duration", "duration_minutes": 0}],
        [{"mode": "duration", "duration_minutes": 1.5}],
        [{"mode": "range", "start_minutes": None, "end_minutes": 600}],
    ],
)
def test_reject_invalid_breaks(breaks):
    with pytest.raises(ValueError):
        calculate_break_minutes(breaks)
