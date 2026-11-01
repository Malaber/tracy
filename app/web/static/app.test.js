import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";

import {
  monthForecast,
  calculateDraft,
  calculateSessions,
  sessionAction,
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
  const stats = { start: "2026-10-01", end: "2026-10-31", weeks: [], summary: { exact_minutes: 0, billable_minutes: 0, target_minutes: 2400, balance_minutes: -2400, completion_percent: 0 }, days: [{ date: entry.date, is_workday: true, status: "in_progress", exact_minutes: 0, billable_minutes: 0, balance_minutes: -480 }] };
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
    document.querySelector('[data-period="month"]').click();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(element("monthForecast").hidden, false);
    assert.equal(element("forecastTotal").textContent, "8.00 h");
    assert.equal(element("forecastBalance").textContent, "32 h 00 min under target");
    document.querySelector('[data-period="year"]').click();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(element("monthForecast").hidden, true);

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


test("project sessions preserve repeated projects, exclude gaps and deduct only long-session breaks", () => {
  let entry = { sessions: [], breaks: [] };
  for (const [action, minute, project] of [["check-in",480,1],["check-out",630,1],["check-in",645,2],["check-out",1140,2],["check-in",1170,1],["check-out",1200,1]]) {
    entry.sessions = sessionAction(entry, action, minute, project);
  }
  assert.deepEqual(calculateSessions(entry.sessions), {exact:645,billable:645,breakMinutes:30});
  entry.sessions[1].end = 977;
  assert.equal(calculateSessions(entry.sessions).breakMinutes,0);
  entry.sessions[1].break_minutes = 0;
  entry.sessions[1].end = 1140;
  assert.equal(calculateSessions(entry.sessions).breakMinutes,0);
  assert.throws(() => sessionAction(entry,"check-in",1199,1), /overlap/);
  entry.sessions = sessionAction(entry,"check-in",1230,2);
  assert.throws(() => sessionAction(entry,"check-in",1240,2), /Check out/);
  const projected = projectEntry({...entry,date:"2026-10-28"},{date:"2026-10-28",clock:"21:00"});
  assert.equal(projected.exact,705);
});


test("session UI saves chosen project and time, renders editable sessions, and keeps revision headers", async () => {
  const { JSDOM } = await import("jsdom");
  const dom = new JSDOM(await fs.readFile(new URL("../templates/index.html", import.meta.url), "utf8"), {url:"https://tracy.example"});
  const keys = ["document","location","fetch","setInterval"];
  const originals = Object.fromEntries(keys.map(key => [key,globalThis[key]]));
  let tick, writes = 0;
  let entry = {date:"2026-10-28",revision:"r0",saved:false,check_in:null,check_out:null,breaks:[],status:"empty"};
  try {
    globalThis.document = dom.window.document;
    globalThis.location = dom.window.location;
    globalThis.setInterval = fn => {tick=fn;};
    dom.window.HTMLDialogElement.prototype.showModal = function() { this.open=true; };
    dom.window.HTMLDialogElement.prototype.close = function() { this.open=false; };
    globalThis.fetch = async (url,options) => {
      let data;
      if(url.endsWith("/meta")) data={timezone:"UTC",federal_states:{}};
      else if(url.endsWith("/preferences")) data={rounding_minutes:15};
      else if(url.endsWith("/projects")) data={projects:[{id:1,name:"X"},{id:2,name:"Y"},{id:3,name:"Archived",archived:true}],default_project_id:1};
      else if(url.includes("/statistics?")) data={summary:{billable_minutes:0,exact_minutes:0,target_minutes:2400},days:[]};
      else if(options.method === "PUT") {
        assert.equal(options.headers["Content-Type"],"application/json");
        assert.equal(options.headers["If-Match"],entry.revision);
        const draft=JSON.parse(options.body);
        const last=draft.sessions.at(-1);
        const clock = minute => `${String(Math.floor(minute/60)).padStart(2,"0")}:${String(minute%60).padStart(2,"0")}`;
        entry={...entry,...draft,saved:true,revision:`r${++writes}`,check_in:clock(draft.sessions[0].start),check_out:last.end == null ? null : clock(last.end),breaks:[],status:last.end == null ? "in_progress":"complete"};
        data=entry;
      } else data=entry;
      return {ok:true,json:async()=>structuredClone(data)};
    };
    await import(`./app.js?session-ui=${Date.now()}`);
    for(let i=0;i<100 && !tick;i++) await new Promise(resolve=>setImmediate(resolve));
    const el=id=>document.getElementById(id);
    for(const [action,time,project] of [["In","08:00","1"],["Out","10:30","1"],["In","10:45","2"],["Out","19:00","2"],["In","19:30","1"],["Out","20:00","1"]]) {
      el(`check${action}Options`).click();
      assert.equal(el("sessionActionDialog").open,true);
      assert.ok(!el("sessionActionProject").textContent.includes("Archived"));
      el("sessionActionProject").value=project;
      el("sessionActionTime").value=time;
      el("sessionActionForm").dispatchEvent(new dom.window.Event("submit",{cancelable:true}));
      for(let i=0;i<30 && el("sessionActionDialog").open;i++) await new Promise(resolve=>setImmediate(resolve));
      assert.equal(el("sessionActionDialog").open,false);
    }
    assert.equal(writes,6);
    assert.equal(el("sessionList").children.length,3);
    assert.equal(el("billableHours").textContent,"10.75");
    assert.equal(el("sessionSection").hidden,false);
    assert.equal(el("checkIn").disabled,true);
    const deduction=el("sessionList").children[1].querySelector(".session-break");
    deduction.value="0";
    deduction.dispatchEvent(new dom.window.Event("input",{bubbles:true}));
    assert.equal(el("billableHours").textContent,"11.25");
    el("saveEntry").click();
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(entry.sessions[1].break_minutes,0);
  } finally {
    for(const [key,value] of Object.entries(originals)) { if(value===undefined) delete globalThis[key]; else globalThis[key]=value; }
    dom.window.close();
  }
});


test("month forecast fills only remaining unfinished workdays and retains overtime", () => {
  const day = (date, billable_minutes = 0, status = "empty", is_workday = true) =>
    ({ date, billable_minutes, status, is_workday });
  const data = { summary: { billable_minutes: 900, target_minutes: 2400 }, days: [
    day("2026-10-01"), // Past missing day remains missing.
    day("2026-10-26", 300, "in_progress"),
    day("2026-10-27", 600, "complete"),
    day("2026-10-28"),
    day("2026-10-29", 0, "empty", false), // Vacation or holiday.
    day("2026-10-31", 0, "empty", false), // Weekend.
  ] };
  assert.deepEqual(monthForecast(data, "2026-10-26"), {
    billableMinutes: 1560, balanceMinutes: -840, remainingDays: 2,
  });
  assert.deepEqual(monthForecast(data, "2026-11-01"), {
    billableMinutes: 900, balanceMinutes: -1500, remainingDays: 0,
  });
  data.days[1].billable_minutes = 540;
  data.summary.billable_minutes = 1140;
  assert.equal(monthForecast(data, "2026-10-26").billableMinutes, 1620);
  data.days[1].status = "complete";
  data.days[1].billable_minutes = 240;
  data.summary.billable_minutes = 840;
  assert.equal(monthForecast(data, "2026-10-26").billableMinutes, 1320);
});
