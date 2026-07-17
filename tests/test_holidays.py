from datetime import date

import pytest

from app.services.german_holidays import (
    easter_sunday,
    german_public_holidays,
    holidays_between,
    is_workday,
    repentance_day,
)


def test_easter_and_moveable_holidays_for_2026():
    assert easter_sunday(2026) == date(2026, 4, 5)
    holidays = german_public_holidays(2026, "DE")
    assert holidays[date(2026, 4, 3)] == "Good Friday"
    assert holidays[date(2026, 5, 14)] == "Ascension Day"


def test_state_specific_holidays_and_historic_rules():
    assert german_public_holidays(2026, "BE")[date(2026, 3, 8)] == "International Women's Day"
    assert date(2018, 3, 8) not in german_public_holidays(2018, "BE")
    assert date(2026, 6, 4) in german_public_holidays(2026, "NW")
    assert date(2026, 8, 15) in german_public_holidays(2026, "SL")
    assert date(2026, 9, 20) in german_public_holidays(2026, "TH")
    assert date(2026, 10, 31) in german_public_holidays(2026, "HH")
    assert date(2017, 10, 31) in german_public_holidays(2017, "DE")
    assert date(2026, 11, 1) in german_public_holidays(2026, "BW")
    assert repentance_day(2026) in german_public_holidays(2026, "SN")
    assert easter_sunday(2026) in german_public_holidays(2026, "BB")


def test_holidays_between_and_workday_detection():
    holidays = holidays_between(date(2026, 12, 20), date(2027, 1, 2), "DE")
    assert set(holidays) == {date(2026, 12, 25), date(2026, 12, 26), date(2027, 1, 1)}
    assert not is_workday(date(2026, 12, 25), holidays)
    assert not is_workday(date(2026, 12, 27), holidays)
    assert is_workday(date(2026, 12, 28), holidays)


def test_unknown_state_is_rejected():
    with pytest.raises(ValueError):
        german_public_holidays(2026, "XX")
