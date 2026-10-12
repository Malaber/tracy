import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

import {
  calculateDraft,
  projectEntry,
  projectStatistics,
  dayProgress,
  formatDuration,
  localISODate,
  needsDefaultBreak,
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

test("new long days get a default break", () => {
  assert.equal(needsDefaultBreak({
    checkIn: "8", checkOut: "12:30", nextDay: false, breaks: [], saved: false,
  }), false);
  assert.equal(needsDefaultBreak({
    checkIn: "8", checkOut: "12:31", nextDay: false, breaks: [], saved: false,
  }), true);
  assert.equal(needsDefaultBreak({
    checkIn: "22", checkOut: "03:00", nextDay: true, breaks: [], saved: false,
  }), true);
  assert.equal(needsDefaultBreak({
    checkIn: "8", checkOut: "17", nextDay: false,
    breaks: [{ mode: "duration", duration_minutes: 15 }], saved: false,
  }), false);
  assert.equal(needsDefaultBreak({
    checkIn: "8", checkOut: "17", nextDay: false, breaks: [], saved: true,
  }), false);
});

test("clock fields use native time controls", async () => {
  const template = await fs.readFile(new URL("../templates/index.html", import.meta.url), "utf8");
  const script = await fs.readFile(new URL("./app.js", import.meta.url), "utf8");
  assert.match(template, /id="checkIn" type="time" step="60"/);
  assert.match(template, /id="checkOut" type="time" step="60"/);
  assert.match(script, /class="break-start" type="time" step="60"/);
  assert.match(script, /class="break-end" type="time" step="60"/);
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

test("live sign-off applies default breaks, rounding and date guards without mutation", () => {
  const entry = { date: "2026-10-12", check_in: "08:00", check_out: null, breaks: [] };
  const now = clock => ({ date: entry.date, clock });
  assert.deepEqual(projectEntry(entry, now("08:00")), { exact: 0, billable: 0, breakMinutes: 0 });
  assert.equal(projectEntry(entry, now("12:30")).exact, 270);
  assert.deepEqual(projectEntry(entry, now("12:31")), { exact: 241, billable: 255, breakMinutes: 30 });
  assert.equal(projectEntry(entry, now("16:31"), 1).billable, 481);
  assert.equal(projectEntry(entry, now("07:59")), null);
  assert.equal(projectEntry(entry, { date: "2026-10-13", clock: "09:00" }), null);
  assert.equal(projectEntry({ ...entry, check_out: "17:00" }, now("18:00")), null);
  assert.equal(projectEntry({ ...entry, breaks: [{ mode: "duration", duration_minutes: 45 }] }, now("16:00")).exact, 435);
  assert.equal(entry.check_out, null);
  assert.deepEqual(entry.breaks, []);
  assert.equal(dayProgress(480).percent, 100);
  assert.equal(dayProgress(600).percent, 100);
  assert.equal(dayProgress(240).percent, 50);
  assert.notEqual(dayProgress(240).color, dayProgress(480).color);
});

test("live statistics replace day contribution without double counting or completing day", () => {
  const data = { summary: { exact_minutes: 480, billable_minutes: 480, balance_minutes: -1920, target_minutes: 2400, completed_days: 1 }, days: [{ date: "2026-10-12", exact_minutes: 0, billable_minutes: 0, balance_minutes: -480 }], weeks: [{ week_start: "2026-10-12", exact_minutes: 480, billable_minutes: 480 }] };
  const entry = { date: "2026-10-12" };
  const estimate = { exact: 241, billable: 255 };
  const result = projectStatistics(data, entry, estimate);
  assert.equal(result.summary.exact_minutes, 721);
  assert.equal(result.summary.billable_minutes, 735);
  assert.equal(result.summary.balance_minutes, -1679);
  assert.equal(result.summary.completed_days, 1);
  assert.equal(result.weeks[0].exact_minutes, 721);
  assert.equal(result.days[0].status, "in_progress");
  assert.deepEqual(projectStatistics(result, entry, estimate), result);
  assert.equal(data.summary.exact_minutes, 480);
  assert.equal(projectStatistics(data, { date: "2025-01-01" }, estimate), data);
});

test("tracker updates live estimates every minute without saving checkout", async () => {
  const { JSDOM } = await import("jsdom");
  const html = await fs.readFile(new URL("../templates/index.html", import.meta.url), "utf8");
  const dom = new JSDOM(html, { url: "https://tracy.example" });
  const originals = Object.fromEntries(["document", "location", "fetch", "Date", "setInterval"].map(key => [key, globalThis[key]]));
  let now = "2026-10-12T12:31:00Z";
  let tick;
  const requests = [];
  const entry = { date: "2026-10-12", saved: true, check_in: "08:00", check_out: null, breaks: [], status: "in_progress" };
  const stats = { summary: { exact_minutes: 0, billable_minutes: 0, target_minutes: 2400, balance_minutes: -2400, completion_percent: 0 }, days: [{ date: entry.date, is_workday: true, status: "in_progress", exact_minutes: 0, billable_minutes: 0, balance_minutes: -480 }] };
  try {
    globalThis.document = dom.window.document;
    globalThis.location = dom.window.location;
    globalThis.Date = class extends originals.Date {
      constructor(...args) { super(...(args.length ? args : [now])); }
    };
    globalThis.setInterval = callback => { tick = callback; };
    globalThis.fetch = async (url, options) => {
      requests.push({ url, options });
      const data = url.endsWith("/meta") ? { timezone: "UTC", federal_states: {} }
        : url.endsWith("/preferences") ? { rounding_minutes: 15 }
        : url.includes("/statistics?") ? stats : entry;
      return { ok: true, json: async () => structuredClone(data) };
    };
    await import(`./app.js?ui-test=${originals.Date.now()}`);
    for (let i = 0; i < 100 && !tick; i++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(typeof tick, "function");
    const element = id => document.getElementById(id);
    assert.equal(element("billableHours").textContent, "4.25");
    assert.equal(element("weekTotal").textContent, "4.02 h / 40.00 h");
    assert.equal(element("checkOut").value, "");
    assert.equal(element("breakList").children.length, 0);
    assert.equal(element("estimateLabel").hidden, false);
    now = "2026-10-12T16:30:00Z";
    tick();
    assert.equal(element("billableHours").textContent, "8.00");
    assert.equal(element("weekTotal").textContent, "8.00 h / 40.00 h");
    assert.equal(element("dayProgressTrack").getAttribute("aria-valuenow"), "100");
    assert.equal(element("dayProgress").style.width, "100%");
    assert.equal(element("dayProgress").style.backgroundImage, "none");
    assert.equal(element("checkOut").value, "");
    assert.ok(requests.every(request => !request.options.method));
  } finally {
    for (const [key, value] of Object.entries(originals)) {
      if (value === undefined) delete globalThis[key]; else globalThis[key] = value;
    }
    dom.window.close();
  }
});
