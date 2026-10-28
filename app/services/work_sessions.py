"""Timed project sessions. Round once per day; assign rounding to the last project."""

from app.services.time_calculation import round_up


def session_totals(sessions: list[dict], rounding: int) -> dict:
    exact = 0
    deductions = 0
    bookings = {}
    previous_end = 0
    last_project = None
    for index, session in enumerate(sessions):
        start, end = session["start"], session.get("end")
        if start < previous_end or (end is None and index != len(sessions) - 1):
            raise ValueError(
                "Sessions must be ordered, without overlaps; only the last may be open."
            )
        if end is None:
            continue
        span = end - start
        deduction = session.get("break_minutes")
        if deduction is None:
            deduction = 30 if span > 360 else 0
        if span <= 0 or deduction >= span:
            raise ValueError(
                "Checkout must follow check-in and breaks must be shorter than the session."
            )
        previous_end = end
        exact += span - deduction
        deductions += deduction
        project = session.get("project_id")
        last_project = project
        if project is not None:
            bookings[project] = bookings.get(project, 0) + span - deduction
    billable = round_up(exact, rounding)
    if last_project in bookings:
        bookings[last_project] += billable - exact
    return dict(
        exact_minutes=exact,
        billable_minutes=billable,
        break_minutes=deductions,
        project_bookings=[dict(project_id=p, minutes=m) for p, m in bookings.items()],
    )
