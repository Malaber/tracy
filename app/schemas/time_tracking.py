from __future__ import annotations

from datetime import date
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from app.services.german_holidays import FEDERAL_STATES
from app.services.time_calculation import calculate_work_minutes, parse_clock_time


class BreakPayload(BaseModel):
    mode: Literal["duration", "range"]
    duration_minutes: int | None = Field(default=None, ge=1, le=1440)
    start: str | None = None
    end: str | None = None

    @model_validator(mode="after")
    def validate_mode_fields(self) -> "BreakPayload":
        if self.mode == "duration":
            if self.duration_minutes is None:
                raise ValueError("A duration break needs a number of minutes.")
            if self.start is not None or self.end is not None:
                raise ValueError("A duration break cannot also have start/end times.")
            return self
        if self.duration_minutes is not None:
            raise ValueError("A range break cannot also have a duration.")
        if not self.start or not self.end:
            raise ValueError("A range break needs both a start and an end time.")
        parse_clock_time(self.start)
        parse_clock_time(self.end)
        return self

    def normalized(self) -> dict[str, int | str | None]:
        return {
            "mode": self.mode,
            "duration_minutes": self.duration_minutes,
            "start_minutes": parse_clock_time(self.start),
            "end_minutes": parse_clock_time(self.end),
        }


class WorkEntryPayload(BaseModel):
    check_in: str | None = None
    check_out: str | None = None
    check_out_next_day: bool = False
    breaks: list[BreakPayload] = Field(default_factory=list, max_length=20)
    notes: str = Field(default="", max_length=2000)

    @field_validator("check_in", "check_out")
    @classmethod
    def validate_clock(cls, value: str | None) -> str | None:
        if value is None or not value.strip():
            return None
        parse_clock_time(value)
        return value.strip()

    @model_validator(mode="after")
    def validate_calculation(self) -> "WorkEntryPayload":
        calculate_work_minutes(
            parse_clock_time(self.check_in),
            parse_clock_time(self.check_out),
            self.check_out_next_day,
            [item.normalized() for item in self.breaks],
        )
        return self


class DayOffRangePayload(BaseModel):
    start: date
    end: date

    @model_validator(mode="after")
    def validate_range(self) -> "DayOffRangePayload":
        if self.end < self.start:
            raise ValueError("End date must be on or after start date.")
        if (self.end - self.start).days > 732:
            raise ValueError("Date range is limited to two years.")
        return self


class PreferencesPayload(BaseModel):
    federal_state: str
    daily_target_minutes: int = Field(ge=0, le=24 * 60)
    rounding_minutes: Literal[1, 5, 10, 15, 30, 60]

    @field_validator("federal_state")
    @classmethod
    def validate_federal_state(cls, value: str) -> str:
        normalized = value.upper()
        if normalized not in FEDERAL_STATES:
            raise ValueError("Choose a valid German federal state.")
        return normalized
