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
    checkIn: "8", checkOut: "14:01", nextDay: false, breaks: [], saved: false,
  }), true);
  assert.equal(needsDefaultBreak({
    checkIn: "22", checkOut: "04:01", nextDay: true, breaks: [], saved: false,
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
  assert.equal(projectEntry(entry, now("12:59")).breakMinutes, 0);
  assert.equal(projectEntry(entry, now("14:00")).exact, 360);
  assert.deepEqual(projectEntry(entry, now("14:01")), { exact: 331, billable: 345, breakMinutes: 30 });
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
  assert.equal(result.summary.balance_minutes, -1665);
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
  let now = "2026-10-12T14:01:00Z";
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
        : url.endsWith("/projects") ? { projects: [], default_project_id: null }
        : url.endsWith("/preferences") ? { rounding_minutes: 15 }
        : url.includes("/statistics?") ? stats : entry;
      return { ok: true, json: async () => structuredClone(data) };
    };
    await import(`./app.js?ui-test=${originals.Date.now()}`);
    for (let i = 0; i < 100 && !tick; i++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(typeof tick, "function");
    const element = id => document.getElementById(id);
    assert.equal(element("billableHours").textContent, "5.75");
    assert.equal(element("weekTotal").textContent, "5.75 h / 40.00 h");
    assert.equal(element("weekBalance").textContent, "−34.25 h");
    assert.ok(Math.abs(parseFloat(element("weekProgress").style.width) - 14.375) < 0.000001);
    assert.equal(element("recentDays").querySelector("strong").textContent, "5.75 h");
    assert.equal(element("breakDeduction").textContent, "0 h 30 min breaks deducted");
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
    assert.equal(requests.filter(request => request.url.includes("/entries/")).length, 1);
    element("previousDay").click();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(element("workDate").value, "2026-10-11");
    assert.equal(element("goToToday").hidden, false);
    element("goToToday").click();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(element("workDate").value, "2026-10-12");
    assert.equal(element("goToToday").hidden, true);
  } finally {
    for (const [key, value] of Object.entries(originals)) {
      if (value === undefined) delete globalThis[key]; else globalThis[key] = value;
    }
    dom.window.close();
  }
});

test("web project bookings preserve defaults and automatic breaks disappear on shorter days", async () => {
  const { JSDOM } = await import("jsdom");
  const html = await fs.readFile(new URL("../templates/index.html", import.meta.url), "utf8");
  const dom = new JSDOM(html, { url: "https://tracy.example" });
  const keys = ["document", "location", "fetch", "setInterval"];
  const originals = Object.fromEntries(keys.map(key => [key, globalThis[key]]));
  let tick, saved;
  const entry = { date: "2026-10-22", saved: false, check_in: "08:44", check_out: "17:00", breaks: [], status: "complete" };
  const projects = { projects: [{ id: 1, name: "X", archived: false }, { id: 2, name: "Y", archived: false }, { id: 3, name: "Old", archived: true }], default_project_id: 1 };
  const stats = { summary: { billable_minutes: 0, exact_minutes: 0, target_minutes: 2400 }, days: [] };
  try {
    globalThis.document = dom.window.document;
    globalThis.location = dom.window.location;
    globalThis.setInterval = fn => { tick = fn; };
    globalThis.fetch = async (url, options) => {
      let data;
      if (url.endsWith("/meta")) data = { timezone: "UTC", federal_states: {} };
      else if (url.endsWith("/preferences")) data = { rounding_minutes: 15 };
      else if (url.endsWith("/projects")) data = projects;
      else if (url.includes("/statistics?")) data = stats;
      else if (options.method === "PUT") { saved = JSON.parse(options.body); data = { ...entry, ...saved, saved: true }; }
      else data = entry;
      return { ok: true, json: async () => structuredClone(data) };
    };
    await import(`./app.js?projects=${Date.now()}`);
    for (let i = 0; i < 100 && !tick; i++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(typeof tick, "function");
    const el = id => document.getElementById(id);
    assert.equal(el("dayProject").value, "1");
    assert.ok(!el("dayProject").textContent.includes("Old"));
    assert.equal(el("breakList").children.length, 1);
    el("checkOut").value = "14:16";
    el("checkOut").dispatchEvent(new dom.window.Event("input"));
    assert.equal(el("breakList").children.length, 0);
    assert.equal(el("billableHours").textContent, "5.75");
    el("addBooking").click();
    const row = el("bookingList").firstChild;
    row.querySelector("select").value = "2";
    row.querySelector("select").dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    assert.equal(row.querySelector("input").value, "2");
    assert.match(el("bookingSummary").textContent, /3 h 45 min to X/);
    el("saveEntry").click();
    for (let i = 0; i < 30 && !saved; i++) await new Promise(resolve => setImmediate(resolve));
    assert.equal(saved.default_project_id, 1);
    assert.deepEqual(saved.project_allocations, [{ project_id: 2, minutes: 120 }]);
    assert.deepEqual(saved.breaks, []);
    await new Promise(resolve => setImmediate(resolve));
  } finally {
    for (const [key, value] of Object.entries(originals)) {
      if (value === undefined) delete globalThis[key]; else globalThis[key] = value;
    }
    dom.window.close();
  }
});
