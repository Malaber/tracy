import assert from "node:assert/strict";
import test from "node:test";

import {
  calculateDraft,
  formatDuration,
  localISODate,
  parseClock,
  roundUp,
  validateDateRange,
} from "./app.js";


test("parseClock supports the calculator formats", () => {
  assert.equal(parseClock(""), null);
  assert.equal(parseClock("8"), 480);
  assert.equal(parseClock("08:30"), 510);
  assert.equal(parseClock("8,5"), 510);
  assert.throws(() => parseClock("24:00"), /between/);
  assert.throws(() => parseClock("abc"), /Use a time/);
  assert.throws(() => parseClock("24"), /between/);
});

test("duration helpers preserve signs and rounding", () => {
  assert.equal(roundUp(481, 15), 495);
  assert.equal(roundUp(481, 1), 481);
  assert.equal(formatDuration(null), "—");
  assert.equal(formatDuration(485), "8 h 05 min");
  assert.equal(formatDuration(-90, { signed: true, decimal: true }), "−1.50 h");
  assert.equal(formatDuration(90, { signed: true, decimal: true }), "+1.50 h");
  assert.match(localISODate(new Date(2026, 6, 18, 12)), /^2026-07-18$/);
});

test("calculateDraft handles breaks, rounding, overnight ranges, and incomplete days", () => {
  assert.deepEqual(calculateDraft({ checkIn: "", checkOut: "", nextDay: false, breaks: [], rounding: 15 }), {
    exact: null, billable: null, breakMinutes: 0,
  });
  assert.deepEqual(calculateDraft({
    checkIn: "8", checkOut: "17:10", nextDay: false, rounding: 15,
    breaks: [
      { mode: "duration", duration_minutes: 15 },
      { mode: "range", start: "12", end: "12:30" },
    ],
  }), { exact: 505, billable: 510, breakMinutes: 45 });
  assert.deepEqual(calculateDraft({
    checkIn: "22", checkOut: "2", nextDay: true, rounding: 1,
    breaks: [{ mode: "range", start: "23:45", end: "0:15" }],
  }), { exact: 210, billable: 210, breakMinutes: 30 });
  assert.throws(() => calculateDraft({ checkIn: "10", checkOut: "9", nextDay: false, breaks: [], rounding: 15 }), /later/);
  assert.throws(() => calculateDraft({ checkIn: "8", checkOut: "9", nextDay: false, breaks: [{ mode: "duration", duration_minutes: 0 }], rounding: 15 }), /positive/);
  assert.throws(() => calculateDraft({ checkIn: "8", checkOut: "9", nextDay: false, breaks: [{ mode: "range", start: "", end: "8:30" }], rounding: 15 }), /need a start/);
  assert.throws(() => calculateDraft({ checkIn: "8", checkOut: "9", nextDay: false, breaks: [{ mode: "range", start: "8:30", end: "8:30" }], rounding: 15 }), /later/);
  assert.throws(() => calculateDraft({ checkIn: "8", checkOut: "9", nextDay: false, breaks: [{ mode: "duration", duration_minutes: 60 }], rounding: 15 }), /shorter/);
});

test("validateDateRange accepts one or multiple dates and rejects invalid ranges", () => {
  assert.deepEqual(validateDateRange("2026-07-18", "2026-07-18"), {
    start: "2026-07-18",
    end: "2026-07-18",
    dayCount: 1,
  });
  assert.deepEqual(validateDateRange(" 2026-07-18 ", "2026-07-20"), {
    start: "2026-07-18",
    end: "2026-07-20",
    dayCount: 3,
  });
  assert.throws(() => validateDateRange("", "2026-07-20"), /both a start and end/);
  assert.throws(() => validateDateRange("2026-02-30", "2026-03-02"), /valid calendar/);
  assert.throws(() => validateDateRange("2026-07-20", "2026-07-18"), /on or after/);
});
