from __future__ import annotations

from datetime import date
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from app.services.german_holidays import FEDERAL_STATES
from app.services.time_calculation import calculate_work_minutes, parse_clock_time


class BreakPayload(BaseModel):
    automatic: bool = False
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
            "automatic": self.automatic,
            "duration_minutes": self.duration_minutes,
            "start_minutes": parse_clock_time(self.start),
            "end_minutes": parse_clock_time(self.end),
        }


class ProjectPayload(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    archived: bool = False

    @field_validator("name")
    @classmethod
    def clean_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Enter a project name.")
        return value


class DefaultProjectPayload(BaseModel):
    project_id: int | None = Field(default=None, gt=0)


class ProjectAllocation(BaseModel):
    project_id: int = Field(gt=0)
    minutes: int = Field(gt=0, le=2880)


class WorkSession(BaseModel):
    project_id: int | None = Field(default=None, gt=0)
    start: int = Field(ge=0, lt=2880)
    end: int | None = Field(default=None, gt=0, le=2880)
    # None means automatic; zero explicitly removes a break.
    break_minutes: int | None = Field(default=None, ge=0, le=1440)


class WorkEntryPayload(BaseModel):
    sessions: list[WorkSession] | None = Field(default=None, max_length=50)
    check_in: str | None = None
    check_out: str | None = None
    check_out_next_day: bool = False
    breaks: list[BreakPayload] = Field(default_factory=list, max_length=20)
    project_allocations: list[ProjectAllocation] | None = Field(default=None, max_length=50)
    default_project_id: int | None = Field(default=None, gt=0)
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
        if self.sessions is not None:
            from app.services.work_sessions import session_totals

            session_totals([item.model_dump() for item in self.sessions], 15)
            return self
        start, end = parse_clock_time(self.check_in), parse_clock_time(self.check_out)
        if (
            start is not None
            and end is not None
            and end + (1440 if self.check_out_next_day else 0) - start <= 360
        ):
            self.breaks = [item for item in self.breaks if not item.automatic]
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
