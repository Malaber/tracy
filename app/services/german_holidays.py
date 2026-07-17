from __future__ import annotations

from datetime import date, timedelta


FEDERAL_STATES = {
    "DE": "Germany · national holidays only",
    "BW": "Baden-Württemberg",
    "BY": "Bavaria",
    "BE": "Berlin",
    "BB": "Brandenburg",
    "HB": "Bremen",
    "HH": "Hamburg",
    "HE": "Hesse",
    "MV": "Mecklenburg-Vorpommern",
    "NI": "Lower Saxony",
    "NW": "North Rhine-Westphalia",
    "RP": "Rhineland-Palatinate",
    "SL": "Saarland",
    "SN": "Saxony",
    "ST": "Saxony-Anhalt",
    "SH": "Schleswig-Holstein",
    "TH": "Thuringia",
}


def easter_sunday(year: int) -> date:
    """Return Gregorian Easter Sunday using the Meeus/Jones/Butcher algorithm."""
    a = year % 19
    b = year // 100
    c = year % 100
    d = b // 4
    e = b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i = c // 4
    k = c % 4
    length = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * length) // 451
    month = (h + length - 7 * m + 114) // 31
    day = ((h + length - 7 * m + 114) % 31) + 1
    return date(year, month, day)


def repentance_day(year: int) -> date:
    current = date(year, 11, 22)
    return current - timedelta(days=(current.weekday() - 2) % 7)


def german_public_holidays(year: int, federal_state: str = "DE") -> dict[date, str]:
    if federal_state not in FEDERAL_STATES:
        raise ValueError(f"Unknown German federal state: {federal_state}")

    easter = easter_sunday(year)
    holidays = {
        date(year, 1, 1): "New Year's Day",
        easter - timedelta(days=2): "Good Friday",
        easter + timedelta(days=1): "Easter Monday",
        date(year, 5, 1): "Labour Day",
        easter + timedelta(days=39): "Ascension Day",
        easter + timedelta(days=50): "Whit Monday",
        date(year, 10, 3): "German Unity Day",
        date(year, 12, 25): "Christmas Day",
        date(year, 12, 26): "Second Day of Christmas",
    }

    if federal_state in {"BW", "BY", "ST"}:
        holidays[date(year, 1, 6)] = "Epiphany"
    if federal_state == "BE" and year >= 2019:
        holidays[date(year, 3, 8)] = "International Women's Day"
    if federal_state == "MV" and year >= 2023:
        holidays[date(year, 3, 8)] = "International Women's Day"
    if federal_state == "BB":
        holidays[easter] = "Easter Sunday"
        holidays[easter + timedelta(days=49)] = "Whit Sunday"
    if federal_state in {"BW", "BY", "HE", "NW", "RP", "SL"}:
        holidays[easter + timedelta(days=60)] = "Corpus Christi"
    if federal_state == "SL":
        holidays[date(year, 8, 15)] = "Assumption Day"
    if federal_state == "TH" and year >= 2019:
        holidays[date(year, 9, 20)] = "World Children's Day"

    reformation_states = {"BB", "MV", "SN", "ST", "TH"}
    if year >= 2018:
        reformation_states |= {"HB", "HH", "NI", "SH"}
    if year == 2017 or federal_state in reformation_states:
        holidays[date(year, 10, 31)] = "Reformation Day"
    if federal_state in {"BW", "BY", "NW", "RP", "SL"}:
        holidays[date(year, 11, 1)] = "All Saints' Day"
    if federal_state == "SN":
        holidays[repentance_day(year)] = "Day of Repentance and Prayer"

    return holidays


def holidays_between(start: date, end: date, federal_state: str) -> dict[date, str]:
    result: dict[date, str] = {}
    for year in range(start.year, end.year + 1):
        result.update(
            day_name
            for day_name in german_public_holidays(year, federal_state).items()
            if start <= day_name[0] <= end
        )
    return result


def is_workday(day: date, holidays: dict[date, str]) -> bool:
    return day.weekday() < 5 and day not in holidays
