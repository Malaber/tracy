export function parseClock(value) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed) return null;
  const colon = trimmed.match(/^(\d{1,2}):(\d{2})$/);
  if (colon) {
    const hours = Number(colon[1]);
    const minutes = Number(colon[2]);
    if (hours >= 0 && hours <= 23 && minutes >= 0 && minutes <= 59) {
      return hours * 60 + minutes;
    }
    throw new Error("Time must be between 00:00 and 23:59.");
  }
  const normalized = trimmed.replace(",", ".");
  if (!/^\d{1,2}(?:\.\d+)?$/.test(normalized)) {
    throw new Error("Use a time such as 8, 8:30, or 8.5.");
  }
  const minutes = Math.round(Number(normalized) * 60);
  if (!Number.isFinite(minutes) || minutes < 0 || minutes >= 24 * 60) {
    throw new Error("Time must be between 00:00 and 23:59.");
  }
  return minutes;
}

export function roundUp(minutes, increment) {
  if (increment <= 1) return minutes;
  return Math.ceil(minutes / increment) * increment;
}

export function formatDuration(minutes, { signed = false, decimal = false } = {}) {
  if (minutes == null) return "—";
  const sign = minutes < 0 ? "−" : signed && minutes > 0 ? "+" : "";
  const absolute = Math.abs(minutes);
  if (decimal) return `${sign}${(absolute / 60).toFixed(2)} h`;
  const hours = Math.floor(absolute / 60);
  const remainder = absolute % 60;
  return `${sign}${hours} h ${String(remainder).padStart(2, "0")} min`;
}

export function calculateDraft({ checkIn, checkOut, nextDay, breaks, rounding }) {
  const start = parseClock(checkIn);
  const end = parseClock(checkOut);
  if (start == null || end == null) return { exact: null, billable: null, breakMinutes: 0 };
  let span = end + (nextDay ? 1440 : 0) - start;
  if (span <= 0) throw new Error("Check-out must be later than check-in.");
  let breakMinutes = 0;
  for (const item of breaks) {
    if (item.automatic && span <= 360) continue;
    if (item.mode === "duration") {
      const duration = Number(item.duration_minutes);
      if (!Number.isInteger(duration) || duration <= 0) {
        throw new Error("Break durations must be positive whole minutes.");
      }
      breakMinutes += duration;
    } else {
      const breakStart = parseClock(item.start);
      const breakEnd = parseClock(item.end);
      if (breakStart == null || breakEnd == null) {
        throw new Error("Break ranges need a start and an end time.");
      }
      let duration = breakEnd - breakStart;
      if (duration < 0) duration += 1440;
      if (duration <= 0) throw new Error("Break end must be later than break start.");
      breakMinutes += duration;
    }
  }
  if (breakMinutes >= span) throw new Error("Breaks must be shorter than the working span.");
  const exact = span - breakMinutes;
  return { exact, billable: roundUp(exact, rounding), breakMinutes };
}

// Projections never populate check-out or persist a default break.
export function projectEntry(entry, { date, clock }, rounding = 15) {
  if (!entry || entry.date !== date) return null;
  if (entry.sessions != null) {
    const last = entry.sessions.at(-1);
    return last && last.end == null && parseClock(clock) >= last.start
      ? calculateSessions(entry.sessions, rounding, parseClock(clock)) : null;
  }
  if (!entry.check_in || entry.check_out) return null;
  const start = parseClock(entry.check_in);
  const end = parseClock(clock);
  if (end < start) return null;
  if (end === start) return { exact: 0, billable: 0, breakMinutes: 0 };
  const breaks = entry.breaks.length || end - start <= 360
    ? entry.breaks : [{ mode: "duration", duration_minutes: 30 }];
  return calculateDraft({ checkIn: entry.check_in, checkOut: clock, nextDay: false, breaks, rounding });
}

export function calculateSessions(sessions, rounding = 15, now = null) {
  let exact = 0, breakMinutes = 0, previousEnd = 0;
  for (const [index, session] of sessions.entries()) {
    if (!Number.isInteger(session.start) || session.start < 0 || session.start >= 2880
      || session.end != null && (!Number.isInteger(session.end) || session.end > 2880)
      || session.break_minutes != null && (!Number.isInteger(session.break_minutes) || session.break_minutes < 0 || session.break_minutes > 1440)) throw new Error("Choose valid session times and break minutes.");
    const end = session.end ?? now;
    if (session.start < previousEnd || (session.end == null && index !== sessions.length - 1)) throw new Error("Sessions must not overlap; only the last may be open.");
    if (end == null || end <= session.start && session.end == null) continue;
    const span = end - session.start;
    const deduction = session.break_minutes ?? (span > 360 ? 30 : 0);
    if (span <= 0 || deduction >= span) throw new Error("Checkout must follow check-in and breaks must be shorter than the session.");
    previousEnd = end;
    exact += span - deduction;
    breakMinutes += deduction;
  }
  return { exact, billable: roundUp(exact, rounding), breakMinutes };
}

export function sessionAction(entry, action, minute, projectId) {
  let sessions = structuredClone(entry.sessions ?? []);
  if (entry.sessions == null && entry.check_in) {
    if (entry.project_allocations?.length) throw new Error("This day has manual project bookings. Keep editing it in the day form; start timed sessions on a new day.");
    const breaks = entry.breaks.reduce((sum, item) => sum + (item.mode === "duration" ? item.duration_minutes : (parseClock(item.end) - parseClock(item.start) + 1440) % 1440), 0);
    sessions = [{ start: parseClock(entry.check_in), end: entry.check_out ? parseClock(entry.check_out) + (entry.check_out_next_day ? 1440 : 0) : null, project_id: entry.default_project_id, break_minutes: entry.breaks.length && entry.breaks.every(item => item.automatic) ? null : breaks || (entry.check_out ? 0 : null) }];
  }
  const last = sessions.at(-1);
  if (action === "check-out") {
    if (!last || last.end != null) throw new Error("Check in before checking out.");
    last.end = minute;
    last.project_id = projectId;
  } else {
    if (last && last.end == null) throw new Error("Check out of the current session first.");
    sessions.push({start: minute, end: null, project_id: projectId, break_minutes: null});
  }
  calculateSessions(sessions);
  return sessions;
}

export function dayProgress(minutes) {
  const fraction = Math.max(0, Math.min(1, (minutes ?? 0) / 480));
  return { percent: fraction * 100, color: `hsl(${35 + 105 * fraction} 75% 45%)` };
}

export function projectStatistics(data, entry, projection) {
  if (!projection || !data.days.some(day => day.date === entry.date)) return data;
  const result = structuredClone(data);
  const day = result.days.find(day => day.date === entry.date);
  const exactDelta = projection.exact - day.exact_minutes;
  const billableDelta = projection.billable - day.billable_minutes;
  day.exact_minutes = projection.exact;
  day.billable_minutes = projection.billable;
  day.balance_minutes += billableDelta;
  day.status = "in_progress";
  result.summary.exact_minutes += exactDelta;
  result.summary.billable_minutes += billableDelta;
  result.summary.balance_minutes += billableDelta;
  result.summary.completion_percent = result.summary.target_minutes
    ? result.summary.billable_minutes / result.summary.target_minutes * 100 : 0;
  for (const week of result.weeks ?? []) {
    if (entry.date >= week.week_start && entry.date <= shiftDate(week.week_start, 6)) {
      week.exact_minutes += exactDelta;
      week.billable_minutes += billableDelta;
    }
  }
  return result;
}

function serverNow() {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
    timeZone: state.meta.timezone || "Europe/Berlin", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date()).map(part => [part.type, part.value]));
  return { date: `${parts.year}-${parts.month}-${parts.day}`, clock: `${parts.hour}:${parts.minute}` };
}

function projectedTotals(data) {
  return projectStatistics(data, state.todayEntry, projectEntry(state.todayEntry, serverNow(), state.preferences.rounding_minutes));
}

// Apply after the live sign-off projection so today's hours are never counted twice.
export function monthForecast(data, today) {
  let addedMinutes = 0;
  let remainingDays = 0;
  for (const day of data.days) {
    if (day.date < today || !day.is_workday || day.status === "complete") continue;
    const addition = Math.max(0, 480 - day.billable_minutes);
    if (addition > 0) remainingDays++;
    addedMinutes += addition;
  }
  const billableMinutes = data.summary.billable_minutes + addedMinutes;
  return { billableMinutes, balanceMinutes: billableMinutes - data.summary.target_minutes, remainingDays };
}

export function needsDefaultBreak({ checkIn, checkOut, nextDay, breaks, saved }) {
  if (saved || breaks.length || !String(checkIn ?? "").trim() || !String(checkOut ?? "").trim()) {
    return false;
  }
  try {
    const start = parseClock(checkIn);
    const end = parseClock(checkOut);
    return end + (nextDay ? 1440 : 0) - start > 6 * 60;
  } catch {
    return false;
  }
}

export function localISODate(value = new Date()) {
  const year = value.getFullYear();
  const month = String(value.getMonth() + 1).padStart(2, "0");
  const day = String(value.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function dateFromISO(value) {
  return new Date(`${value}T12:00:00`);
}

function shiftDate(value, days) {
  const date = dateFromISO(value);
  date.setDate(date.getDate() + days);
  return localISODate(date);
}

export function validateDateRange(start, end) {
  const normalizedStart = String(start ?? "").trim();
  const normalizedEnd = String(end ?? "").trim();
  if (!normalizedStart || !normalizedEnd) {
    throw new Error("Choose both a start and end date.");
  }
  const datePattern = /^\d{4}-\d{2}-\d{2}$/;
  const validDate = (value) => {
    if (!datePattern.test(value)) return false;
    const parsed = dateFromISO(value);
    return !Number.isNaN(parsed.getTime()) && localISODate(parsed) === value;
  };
  if (!validDate(normalizedStart) || !validDate(normalizedEnd)) {
    throw new Error("Choose valid calendar dates.");
  }
  if (normalizedEnd < normalizedStart) {
    throw new Error("The end date must be on or after the start date.");
  }
  const startMilliseconds = Date.parse(`${normalizedStart}T00:00:00Z`);
  const endMilliseconds = Date.parse(`${normalizedEnd}T00:00:00Z`);
  return {
    start: normalizedStart,
    end: normalizedEnd,
    dayCount: Math.round((endMilliseconds - startMilliseconds) / 86_400_000) + 1,
  };
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function api(path, options = {}) {
  const response = await fetch(`/api/v1${path}`, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
  });
  if (!response.ok) {
    let message = `Request failed (${response.status}).`;
    try {
      const payload = await response.json();
      if (Array.isArray(payload.detail)) {
        message = payload.detail.map((item) => item.msg.replace(/^Value error, /, "")).join(" ");
      } else if (payload.detail) {
        message = payload.detail;
      }
    } catch { /* Keep the fallback message for non-JSON failures. */ }
    throw new Error(message);
  }
  if (response.status === 204) return null;
  return response.json();
}

const state = {
  currentDate: localISODate(),
  entry: null,
  projects: { projects: [], default_project_id: null },
  todayEntry: null,
  weekData: null,
  statisticsData: null,
  preferences: { federal_state: "DE", daily_target_minutes: 480, rounding_minutes: 15 },
  meta: { federal_states: {} },
  period: "month",
  statisticsAnchor: localISODate(),
};

const byId = (id) => document.getElementById(id);

function showToast(message) {
  const toast = byId("toast");
  toast.textContent = message;
  toast.classList.add("is-visible");
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => toast.classList.remove("is-visible"), 2600);
}

function showFormError(message = "") {
  const error = byId("formError");
  error.textContent = message;
  error.hidden = !message;
}

function updateDateHeading() {
  const date = dateFromISO(state.currentDate);
  const today = serverNow().date;
  byId("goToToday").hidden = state.currentDate === today;
  byId("workDate").value = state.currentDate;
  byId("entryWeekday").textContent = state.currentDate === today
    ? "Today"
    : new Intl.DateTimeFormat("en", { weekday: "long" }).format(date);
  byId("entryDateHeading").textContent = new Intl.DateTimeFormat("en", {
    day: "2-digit", month: "long", year: "numeric",
  }).format(date);
}

function setDayStatus(status, isDayOff = false) {
  const statusEl = byId("dayStatus");
  const labels = {
    empty: "No time saved for this day",
    in_progress: "Working day in progress",
    complete: "Working day complete",
  };
  if (isDayOff) {
    const vacationLabels = {
      empty: "Vacation — no target hours",
      in_progress: "Vacation · Work in progress",
      complete: "Vacation · Working time saved",
    };
    statusEl.className = "day-status is-vacation";
    statusEl.lastElementChild.textContent = vacationLabels[status] || vacationLabels.empty;
    return;
  }
  statusEl.className = `day-status is-${status === "in_progress" ? "progress" : status}`;
  statusEl.lastElementChild.textContent = labels[status] || labels.empty;
}

function addBreakRow(item = { mode: "duration", duration_minutes: 30, start: "", end: "" }) {
  const row = document.createElement("div");
  row.className = "break-row";
  row.dataset.automatic = String(Boolean(item.automatic));
  row.innerHTML = `
    <select class="break-mode" aria-label="Break entry type">
      <option value="duration">Duration</option>
      <option value="range">Start / end</option>
    </select>
    <div class="break-values"></div>
    <button class="remove-break" type="button" aria-label="Remove break">×</button>
  `;
  const mode = row.querySelector(".break-mode");
  mode.value = item.mode;
  const renderFields = () => {
    const values = row.querySelector(".break-values");
    if (mode.value === "duration") {
      values.className = "break-values";
      values.innerHTML = `<input class="break-duration" type="number" min="1" max="1440" step="1" aria-label="Break duration in minutes" placeholder="Minutes" value="${escapeHtml(item.duration_minutes ?? 30)}">`;
    } else {
      values.className = "break-values range-inputs";
      values.innerHTML = `<input class="break-start" type="time" step="60" aria-label="Break start" value="${escapeHtml(item.start ?? "")}"><input class="break-end" type="time" step="60" aria-label="Break end" value="${escapeHtml(item.end ?? "")}">`;
    }
    values.querySelectorAll("input").forEach((input) => input.addEventListener("input", () => { row.dataset.automatic = "false"; updateLiveSummary(); }));
  };
  mode.addEventListener("change", () => {
    row.dataset.automatic = "false";
    item = { mode: mode.value, duration_minutes: 30, start: "", end: "" };
    renderFields();
    updateLiveSummary();
  });
  row.querySelector(".remove-break").addEventListener("click", () => {
    row.remove();
    updateEmptyBreaks();
    updateLiveSummary();
  });
  renderFields();
  byId("breakList").append(row);
  updateEmptyBreaks();
  updateLiveSummary();
}

function updateEmptyBreaks() {
  byId("emptyBreaks").hidden = Boolean(byId("breakList").children.length);
}

function collectBreaks() {
  return [...byId("breakList").querySelectorAll(".break-row")].map((row) => {
    const mode = row.querySelector(".break-mode").value;
    if (mode === "duration") {
      return { mode, automatic: row.dataset.automatic === "true", duration_minutes: Number(row.querySelector(".break-duration").value) };
    }
    return {
      mode,
      duration_minutes: null,
      start: row.querySelector(".break-start").value,
      end: row.querySelector(".break-end").value,
    };
  });
}

function collectDraft() {
  return {
    sessions: state.entry?.sessions == null ? null : collectSessions(),
    check_in: byId("checkIn").value.trim() || null,
    check_out: byId("checkOut").value.trim() || null,
    check_out_next_day: byId("nextDayCheckout").checked,
    breaks: collectBreaks(),
    notes: byId("notes").value,
    default_project_id: Number(byId("dayProject").value) || null,
    project_allocations: collectBookings(),
  };
}

function updateLiveSummary() {
  try {
    let draft = collectDraft();
    if (draft.check_in && draft.check_out && parseClock(draft.check_out) + (draft.check_out_next_day ? 1440 : 0) - parseClock(draft.check_in) <= 360) {
      byId("breakList").querySelectorAll('[data-automatic="true"]').forEach(row => row.remove());
      updateEmptyBreaks();
      draft = collectDraft();
    }
    if (draft.sessions == null && needsDefaultBreak({
      checkIn: draft.check_in,
      checkOut: draft.check_out,
      nextDay: draft.check_out_next_day,
      breaks: draft.breaks,
      saved: Boolean(state.entry?.saved && state.entry?.check_in && state.entry?.check_out),
    })) {
      addBreakRow({ mode: "duration", duration_minutes: 30, automatic: true });
      draft = collectDraft();
    }
    const projection = projectEntry({ ...draft, date: state.currentDate }, serverNow(), state.preferences.rounding_minutes);
    const calculated = projection ?? (draft.sessions != null ? calculateSessions(draft.sessions, state.preferences.rounding_minutes) : calculateDraft({
      checkIn: draft.check_in,
      checkOut: draft.check_out,
      nextDay: draft.check_out_next_day,
      breaks: draft.breaks,
      rounding: state.preferences.rounding_minutes,
    }));
    if (draft.sessions != null) {
      [...byId("sessionList").children].forEach((row, index) => {
        const session = draft.sessions[index];
        const result = calculateSessions([session], 1, state.currentDate === serverNow().date ? parseClock(serverNow().clock) : null);
        row.querySelector(".session-result").textContent = `${formatDuration(result.exact)} working · ${formatDuration(result.breakMinutes)} break deducted`;
      });
    }
    byId("estimateLabel").hidden = !projection;
    const progress = dayProgress(calculated.billable);
    byId("dayProgress").style.width = `${progress.percent}%`;
    byId("dayProgress").style.background = progress.color;
    byId("dayProgressTrack").setAttribute("aria-valuenow", String(progress.percent));
    byId("dayProgressText").textContent = `${formatDuration(calculated.billable)} / 8 h billable`;
    byId("billableHours").textContent = calculated.billable == null
      ? "—"
      : (calculated.billable / 60).toFixed(2);
    byId("exactDuration").textContent = formatDuration(calculated.exact);
    byId("breakDuration").textContent = calculated.breakMinutes
      ? formatDuration(calculated.breakMinutes)
      : "0 min";
    byId("breakDeduction").textContent = calculated.exact == null ? "" : `${formatDuration(calculated.breakMinutes)} breaks deducted`;
    const increment = state.preferences.rounding_minutes;
    byId("roundingDescription").textContent = increment === 1 ? "No rounding" : `Next ${increment} min`;
    const booked = draft.project_allocations.reduce((sum, item) => sum + item.minutes, 0);
    const remaining = Math.max(0, (calculated.billable ?? 0) - booked);
    const project = state.projects.projects.find(item => item.id === draft.default_project_id);
    byId("bookingSummary").textContent = `${formatDuration(booked)} explicitly booked · ${formatDuration(remaining)} ${project ? "to " + project.name : "unassigned"}`;
    if (calculated.billable != null && draft.check_out && booked > calculated.billable) throw new Error("Project bookings exceed this day's billable time.");
    showFormError();
  } catch (error) {
    byId("breakDeduction").textContent = "";
    byId("billableHours").textContent = "—";
    byId("exactDuration").textContent = "—";
    byId("estimateLabel").hidden = true;
    byId("dayProgress").style.width = "0%";
    byId("dayProgressTrack").setAttribute("aria-valuenow", "0");
    byId("dayProgressText").textContent = "— / 8 h";
    showFormError(error.message);
  }
  if (state.weekData) renderWeekSummary(state.weekData);
  if (state.statisticsData) renderStatistics(state.statisticsData);
}

function renderProjectOptions(select, selected) {
  select.innerHTML = '<option value="">Unassigned</option>' + state.projects.projects
    .filter(item => !item.archived || item.id === selected)
    .map(item => `<option value="${item.id}">${escapeHtml(item.name)}${item.archived ? " (archived)" : ""}</option>`).join("");
  select.value = selected || "";
}

function collectBookings() {
  return [...byId("bookingList").children].map(row => ({
    project_id: Number(row.querySelector("select").value),
    minutes: Math.round(Number(row.querySelector("input").value) * 60),
  }));
}

function addBookingRow(item = {}) {
  const row = document.createElement("div");
  row.className = "break-row";
  row.innerHTML = '<select aria-label="Booking project"></select><input type="number" min="0.0166666667" max="48" step="any" aria-label="Billable hours"><button type="button" aria-label="Remove booking">×</button>';
  renderProjectOptions(row.querySelector("select"), item.project_id);
  row.querySelector("select").querySelector('option[value=""]').textContent = "Choose project";
  row.querySelector("input").value = (item.minutes ?? 120) / 60;
  row.addEventListener("input", updateLiveSummary);
  row.querySelector("button").onclick = () => { row.remove(); updateLiveSummary(); };
  byId("bookingList").append(row);
}

function renderProjects() {
  renderProjectOptions(byId("defaultProject"), state.projects.default_project_id);
  byId("projectCatalog").replaceChildren();
  for (const project of state.projects.projects) {
    const row = document.createElement("div");
    row.className = "project-catalog-row";
    const label = document.createElement("span");
    label.className = "project-catalog-name";
    label.textContent = project.name + (project.archived ? " (archived) " : " ");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = project.archived ? "Unarchive" : "Archive";
    button.className = "secondary-button compact";
    button.onclick = () => projectMutation(`/projects/${project.id}`, "PUT", { name: project.name, archived: !project.archived });
    row.append(label, button);
    byId("projectCatalog").append(row);
  }
  const selected = state.entry?.saved ? Number(byId("dayProject").value) || null : state.projects.default_project_id;
  renderProjectOptions(byId("dayProject"), selected);
  for (const row of byId("bookingList").children) renderProjectOptions(row.querySelector("select"), Number(row.querySelector("select").value));
  updateLiveSummary();
}

async function projectMutation(path, method, body) {
  try {
    byId("projectError").textContent = "";
    state.projects = await api(path, { method, body: JSON.stringify(body) });
    renderProjects();
    return true;
  } catch (error) { byId("projectError").textContent = error.message; return false; }
}

function setupProjects() {
  byId("manageProjects").onclick = () => { renderProjects(); byId("projectsDialog").showModal(); };
  byId("closeProjects").onclick = () => byId("projectsDialog").close();
  byId("defaultProject").onchange = event => projectMutation("/projects/default", "PUT", { project_id: Number(event.target.value) || null });
  byId("dayProject").onchange = updateLiveSummary;
  byId("addBooking").onclick = () => { addBookingRow(); updateLiveSummary(); };
  byId("createProjectForm").onsubmit = async event => {
    event.preventDefault();
    if (await projectMutation("/projects", "POST", { name: byId("projectName").value.trim() })) byId("projectName").value = "";
  };
}

function renderEntry(entry) {
  state.entry = entry;
  renderSessions(entry.sessions);
  if (entry.date === serverNow().date) state.todayEntry = entry;
  byId("checkIn").value = entry.check_in || "";
  byId("checkOut").value = entry.check_out || "";
  byId("nextDayCheckout").checked = entry.check_out_next_day;
  byId("notes").value = entry.notes || "";
  renderProjectOptions(byId("dayProject"), entry.saved ? entry.default_project_id : state.projects.default_project_id);
  byId("bookingList").replaceChildren();
  (entry.project_allocations || []).forEach(addBookingRow);
  byId("breakList").replaceChildren();
  entry.breaks.forEach(addBreakRow);
  updateEmptyBreaks();
  setDayStatus(entry.status, entry.is_day_off);
  byId("deleteDay").disabled = !entry.saved;
  const vacationAction = byId("vacationAction");
  vacationAction.classList.toggle("is-active", entry.is_day_off);
  vacationAction.setAttribute("aria-pressed", String(Boolean(entry.is_day_off)));
  vacationAction.textContent = entry.is_day_off ? "Manage vacation" : "Mark vacation";
  updateLiveSummary();
}

async function loadEntry() {
  updateDateHeading();
  showFormError();
  try {
    renderEntry(await api(`/entries/${state.currentDate}`));
  } catch (error) {
    showFormError(error.message);
  }
}

async function changeDate(value) {
  state.currentDate = value;
  await Promise.all([loadEntry(), loadWeekSummary()]);
}

async function saveEntry() {
  const button = byId("saveEntry");
  button.disabled = true;
  showFormError();
  try {
    renderEntry(await api(`/entries/${state.currentDate}`, {
      method: "PUT",
      headers: { "If-Match": state.entry?.revision ?? "missing" },
      body: JSON.stringify(collectDraft()),
    }));
    showToast("Working day saved.");
    await loadWeekSummary();
  } catch (error) {
    showFormError(error.message);
  } finally {
    button.disabled = false;
  }
}

async function timeAction(action, minute = parseClock(serverNow().clock), projectId = undefined) {
  showFormError();
  try {
    const draft = collectDraft();
    const entry = { ...state.entry, ...draft };
    const selected = projectId === undefined ? (action === "check-out" ? (entry.sessions != null ? entry.sessions.at(-1)?.project_id ?? null : entry.default_project_id) : state.projects.default_project_id) : projectId;
    const sessions = sessionAction(entry, action, minute, selected);
    renderEntry(await api(`/entries/${state.currentDate}`, {
      method: "PUT", headers: { "If-Match": state.entry?.revision ?? "missing" },
      body: JSON.stringify({ ...draft, sessions }),
    }));
    byId("sessionActionDialog").close();
    showToast(action === "check-in" ? "Checked in." : "Checked out.");
    await loadWeekSummary();
  } catch (error) {
    showFormError(error.message);
    byId("sessionActionError").textContent = error.message;
  }
}

function openSessionAction(action) {
  const dialog = byId("sessionActionDialog");
  dialog.dataset.action = action;
  byId("sessionActionHeading").textContent = action === "check-in" ? "Check in" : "Check out";
  byId("sessionActionTime").value = serverNow().clock;
  byId("sessionActionNextDay").checked = false;
  renderProjectOptions(byId("sessionActionProject"), action === "check-out" ? (state.entry?.sessions != null ? state.entry.sessions.at(-1)?.project_id ?? null : state.entry?.default_project_id) : state.projects.default_project_id);
  byId("sessionActionError").textContent = "";
  dialog.showModal();
}

function collectSessions() {
  return [...byId("sessionList").children].map(row => ({
    project_id: Number(row.querySelector("select").value) || null,
    start: parseClock(row.querySelector(".session-start").value) + (row.querySelector(".session-start-next").checked ? 1440 : 0),
    end: row.querySelector(".session-end").value ? parseClock(row.querySelector(".session-end").value) + (row.querySelector(".session-end-next").checked ? 1440 : 0) : null,
    break_minutes: row.querySelector(".session-break").value === "" ? null : Number(row.querySelector(".session-break").value),
  }));
}

function renderSessions(sessions) {
  const active = sessions != null;
  byId("sessionSection").hidden = !active;
  byId("breakHeading").closest("section").hidden = active;
  byId("projectsHeading").closest("section").hidden = active;
  for (const id of ["checkIn", "checkOut", "nextDayCheckout"]) byId(id).disabled = active;
  byId("sessionList").replaceChildren();
  for (const [index, session] of (sessions ?? []).entries()) {
    const row = document.createElement("div");
    row.className = "session-row";
    row.innerHTML = `<strong>Session ${index + 1}</strong><label>Project<select></select></label><label>Check-in<input class="session-start" type="time" required></label><label class="session-checkbox"><input class="session-start-next" type="checkbox"> Starts next day</label><label>Check-out<input class="session-end" type="time"></label><label class="session-checkbox"><input class="session-end-next" type="checkbox"> Ends next day</label><label>Break minutes<input class="session-break" type="number" min="0" max="1440" placeholder="Automatic after 6 hours"></label><button type="button" class="text-button">Remove session</button><p class="session-result"></p>`;
    renderProjectOptions(row.querySelector("select"), session.project_id);
    const clock = value => value == null ? "" : `${String(Math.floor(value % 1440 / 60)).padStart(2,"0")}:${String(value % 60).padStart(2,"0")}`;
    row.querySelector(".session-start").value = clock(session.start);
    row.querySelector(".session-end").value = clock(session.end);
    row.querySelector(".session-start-next").checked = session.start >= 1440;
    row.querySelector(".session-end-next").checked = session.end >= 1440;
    row.querySelector(".session-break").value = session.break_minutes ?? "";
    row.querySelector("button").onclick = () => { row.remove(); updateLiveSummary(); };
    row.addEventListener("input", updateLiveSummary);
    byId("sessionList").append(row);
  }
}

async function deleteDay() {
  try {
    await api(`/entries/${state.currentDate}`, { method: "DELETE" });
    byId("deleteDialog").close();
    await loadEntry();
    await loadWeekSummary();
    showToast("Working day cleared.");
  } catch (error) {
    byId("deleteDialog").close();
    showFormError(error.message);
  }
}

function showVacationError(message = "") {
  const error = byId("vacationError");
  error.textContent = message;
  error.hidden = !message;
}

let pendingVacationRemovalKey = null;

function resetVacationRemovalConfirmation() {
  pendingVacationRemovalKey = null;
  const button = byId("removeVacation");
  button.textContent = "Remove vacation";
  button.classList.remove("filled");
  const hint = byId("vacationRemovalHint");
  hint.textContent = "";
  hint.hidden = true;
}

function openVacationDialog() {
  byId("vacationStart").value = state.currentDate;
  byId("vacationEnd").value = state.currentDate;
  showVacationError();
  resetVacationRemovalConfirmation();
  byId("vacationDialog").showModal();
}

async function updateVacation(method, selectedRange = null) {
  let range = selectedRange;
  if (range === null) {
    try {
      range = validateDateRange(byId("vacationStart").value, byId("vacationEnd").value);
    } catch (error) {
      showVacationError(error.message);
      return;
    }
  }

  const markButton = byId("confirmVacation");
  const removeButton = byId("removeVacation");
  markButton.disabled = true;
  removeButton.disabled = true;
  showVacationError();
  try {
    if (method === "PUT") {
      await api("/days-off", {
        method,
        body: JSON.stringify({ start: range.start, end: range.end }),
      });
    } else {
      const query = new URLSearchParams({ start: range.start, end: range.end });
      await api(`/days-off?${query}`, { method });
    }
    byId("vacationDialog").close();
    await Promise.all([loadEntry(), loadWeekSummary(), loadStatistics()]);
    const dates = `${range.dayCount} ${range.dayCount === 1 ? "date" : "dates"}`;
    showToast(method === "PUT" ? `Vacation saved for ${dates}.` : `Vacation removed from ${dates}.`);
  } catch (error) {
    showVacationError(error.message);
  } finally {
    markButton.disabled = false;
    removeButton.disabled = false;
    resetVacationRemovalConfirmation();
  }
}

function saveVacation(event) {
  event.preventDefault();
  return updateVacation("PUT");
}

function requestVacationRemoval() {
  let range;
  try {
    range = validateDateRange(byId("vacationStart").value, byId("vacationEnd").value);
  } catch (error) {
    showVacationError(error.message);
    return;
  }
  showVacationError();
  const key = `${range.start}:${range.end}`;
  if (pendingVacationRemovalKey !== key) {
    pendingVacationRemovalKey = key;
    const dates = `${range.dayCount} ${range.dayCount === 1 ? "date" : "dates"}`;
    byId("removeVacation").textContent = `Confirm remove ${dates}`;
    byId("removeVacation").classList.add("filled");
    const hint = byId("vacationRemovalHint");
    hint.textContent = "This only removes the vacation markers; recorded working time stays saved.";
    hint.hidden = false;
    return;
  }
  return updateVacation("DELETE", range);
}

function renderWeekSummary(data) {
  const projected = projectedTotals(data);
  byId("weekEstimate").hidden = projected === data;
  data = projected;
  const summary = data.summary;
  const balance = summary.billable_minutes - summary.target_minutes;
  const completion = summary.target_minutes ? summary.billable_minutes / summary.target_minutes * 100 : 0;
  byId("weekTotal").textContent = `${formatDuration(summary.billable_minutes, { decimal: true })} / ${formatDuration(summary.target_minutes, { decimal: true })}`;
  byId("weekBalance").textContent = formatDuration(balance, { signed: true, decimal: true });
  byId("weekBalance").className = `balance-badge ${balance > 0 ? "is-positive" : balance < 0 ? "is-negative" : ""}`;
  byId("weekProgress").style.width = `${Math.min(100, completion)}%`;
  const rows = data.days.filter((day) => day.is_workday || day.is_day_off || day.status !== "empty").slice(0, 5);
  byId("recentDays").innerHTML = rows.map((day) => {
    const date = dateFromISO(day.date);
    const letter = new Intl.DateTimeFormat("en", { weekday: "short" }).format(date).slice(0, 1);
    const classes = [
      "recent-day",
      day.status === "complete" ? "is-complete" : "",
      day.is_day_off ? "is-vacation" : "",
    ].filter(Boolean).join(" ");
    const vacation = day.is_day_off ? '<small class="vacation-label">Vacation</small>' : "";
    return `<div class="${classes}"><div><i>${letter}</i><span>${new Intl.DateTimeFormat("en", { weekday: "short", day: "2-digit" }).format(date)}${vacation}</span></div><strong>${day.billable_minutes ? formatDuration(day.billable_minutes, { decimal: true }) : "—"}</strong></div>`;
  }).join("");
}

async function loadWeekSummary() {
  try {
    state.weekData = await api(`/statistics?period=week&anchor=${state.currentDate}`);
    renderWeekSummary(state.weekData);
  } catch (error) {
    showToast(error.message);
  }
}

function renderStatistics(data) {
  const projected = projectedTotals(data);
  byId("statisticsEstimate").hidden = projected === data;
  data = projected;
  const summary = data.summary;
  byId("monthForecast").hidden = state.period !== "month";
  if (state.period === "month") {
    const forecast = monthForecast(data, serverNow().date);
    byId("forecastTotal").textContent = formatDuration(forecast.billableMinutes, { decimal: true });
    byId("forecastBalance").textContent = forecast.balanceMinutes === 0 ? "On target" :
      `${formatDuration(Math.abs(forecast.balanceMinutes))} ${forecast.balanceMinutes > 0 ? "over" : "under"} target`;
    byId("forecastBalance").className = forecast.balanceMinutes >= 0 ? "positive" : "negative";
    byId("forecastAssumption").textContent = `Assumes 8h on ${forecast.remainingDays} remaining unfinished workdays, topping up today. Weekends, holidays and vacation excluded. Completed days stay unchanged.`;
  }

  const start = dateFromISO(data.start);
  const end = dateFromISO(data.end);
  const dateFormat = new Intl.DateTimeFormat("en", { day: "2-digit", month: "short", year: "numeric" });
  byId("statisticsRange").textContent = `${dateFormat.format(start)} – ${dateFormat.format(end)}`;
  byId("projectTotals").replaceChildren();
  for (const total of data.project_totals || []) {
    const row = document.createElement("p");
    row.textContent = `${state.projects.projects.find(item => item.id === total.project_id)?.name || "Project " + total.project_id}: ${formatDuration(total.minutes)}`;
    byId("projectTotals").append(row);
  }
  byId("statExact").textContent = formatDuration(summary.exact_minutes, { decimal: true });
  byId("statBillable").textContent = formatDuration(summary.billable_minutes, { decimal: true });
  byId("statTarget").textContent = formatDuration(summary.target_minutes, { decimal: true });
  byId("statBalance").textContent = formatDuration(summary.balance_minutes, { signed: true, decimal: true });
  byId("statBalance").className = summary.balance_minutes >= 0 ? "positive" : "negative";
  byId("statCompleted").textContent = `${summary.completed_days} completed ${summary.completed_days === 1 ? "day" : "days"}`;
  byId("statWorkdays").textContent = `${summary.expected_workdays} working days`;
  byId("calendarWorkdays").textContent = summary.expected_workdays;
  byId("calendarWeekends").textContent = summary.weekend_days;
  byId("calendarHolidays").textContent = summary.holiday_workdays;
  byId("calendarDaysOff").textContent = summary.day_off_workdays;

  const maximum = Math.max(1, ...data.weeks.flatMap((week) => [week.billable_minutes, week.target_minutes]));
  byId("weeklyChart").innerHTML = data.weeks.map((week) => {
    const weekDate = dateFromISO(week.week_start);
    return `<div class="chart-column" title="${formatDuration(week.billable_minutes)} billable · ${formatDuration(week.target_minutes)} target"><div class="chart-bars"><span class="chart-bar" style="height:${Math.max(2, week.billable_minutes / maximum * 100)}%"></span><span class="chart-bar target" style="height:${Math.max(2, week.target_minutes / maximum * 100)}%"></span></div><small>${weekDate.getDate()} ${weekDate.toLocaleString("en", { month: "short" })}</small></div>`;
  }).join("");

  const visibleDays = state.period === "year"
    ? data.days.filter((day) => day.status !== "empty" || day.holiday || day.is_day_off)
    : data.days;
  byId("statisticsDays").innerHTML = visibleDays.map((day) => {
    const calendarLabels = [];
    if (day.is_day_off) {
      calendarLabels.push('<span class="calendar-pill vacation">Vacation</span>');
    }
    if (day.holiday) {
      calendarLabels.push(`<span class="calendar-pill holiday" title="${escapeHtml(day.holiday)}">${escapeHtml(day.holiday)}</span>`);
    } else if (day.is_weekend) {
      calendarLabels.push('<span class="calendar-pill">Weekend</span>');
    } else if (!day.is_day_off) {
      calendarLabels.push("Working day");
    }
    const calendar = `<span class="calendar-pills">${calendarLabels.join("")}</span>`;
    const balanceClass = day.balance_minutes >= 0 ? "positive" : "negative";
    return `<tr><td><strong>${new Intl.DateTimeFormat("en", { day: "2-digit", month: "short", year: "numeric" }).format(dateFromISO(day.date))}</strong></td><td>${day.weekday}</td><td>${calendar}</td><td>${day.exact_minutes ? formatDuration(day.exact_minutes) : "—"}</td><td>${day.billable_minutes ? formatDuration(day.billable_minutes) : "—"}</td><td class="${balanceClass}">${day.is_workday || day.exact_minutes ? formatDuration(day.balance_minutes, { signed: true }) : "—"}</td></tr>`;
  }).join("");
}

async function loadStatistics() {
  try {
    state.statisticsData = await api(`/statistics?period=${state.period}&anchor=${state.statisticsAnchor}`);
    renderStatistics(state.statisticsData);
    byId("exportCsv").href = `/api/v1/statistics/export.csv?period=${state.period}&anchor=${state.statisticsAnchor}`;
  } catch (error) {
    showToast(error.message);
  }
}

function switchView(view) {
  const tracker = view === "tracker";
  byId("trackerView").hidden = !tracker;
  byId("statisticsView").hidden = tracker;
  document.querySelectorAll("[data-view]").forEach((button) => button.classList.toggle("is-active", button.dataset.view === view));
  history.replaceState(null, "", `#${view}`);
  if (!tracker) loadStatistics();
}

function openSettings() {
  byId("federalState").value = state.preferences.federal_state;
  byId("dailyTarget").value = state.preferences.daily_target_minutes / 60;
  byId("roundingMinutes").value = state.preferences.rounding_minutes;
  byId("settingsError").hidden = true;
  byId("settingsDialog").showModal();
}

async function saveSettings(event) {
  event.preventDefault();
  const error = byId("settingsError");
  error.hidden = true;
  try {
    state.preferences = await api("/preferences", {
      method: "PUT",
      body: JSON.stringify({
        federal_state: byId("federalState").value,
        daily_target_minutes: Math.round(Number(byId("dailyTarget").value) * 60),
        rounding_minutes: Number(byId("roundingMinutes").value),
      }),
    });
    byId("settingsDialog").close();
    updateLiveSummary();
    await Promise.all([loadWeekSummary(), loadStatistics()]);
    showToast("Settings saved.");
  } catch (caught) {
    error.textContent = caught.message;
    error.hidden = false;
  }
}

function shiftStatistics(direction) {
  const anchor = dateFromISO(state.statisticsAnchor);
  if (state.period === "week") anchor.setDate(anchor.getDate() + direction * 7);
  if (state.period === "month") anchor.setMonth(anchor.getMonth() + direction);
  if (state.period === "year") anchor.setFullYear(anchor.getFullYear() + direction);
  state.statisticsAnchor = localISODate(anchor);
  loadStatistics();
}

async function initialize() {
  [state.meta, state.preferences, state.projects] = await Promise.all([api("/meta"), api("/preferences"), api("/projects")]);
  setupProjects();
  byId("checkInOptions").onclick = () => openSessionAction("check-in");
  byId("checkOutOptions").onclick = () => openSessionAction("check-out");
  byId("closeSessionAction").onclick = () => byId("sessionActionDialog").close();
  byId("sessionActionForm").onsubmit = event => {
    event.preventDefault();
    timeAction(byId("sessionActionDialog").dataset.action,
      parseClock(byId("sessionActionTime").value) + (byId("sessionActionNextDay").checked ? 1440 : 0),
      Number(byId("sessionActionProject").value) || null);
  };
  state.currentDate = serverNow().date;
  byId("federalState").innerHTML = Object.entries(state.meta.federal_states)
    .map(([code, name]) => `<option value="${code}">${escapeHtml(name)}</option>`).join("");
  document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => switchView(button.dataset.view)));
  document.querySelectorAll("[data-period]").forEach((button) => button.addEventListener("click", () => {
    state.period = button.dataset.period;
    document.querySelectorAll("[data-period]").forEach((item) => item.classList.toggle("is-active", item === button));
    loadStatistics();
  }));
  byId("previousDay").addEventListener("click", () => changeDate(shiftDate(state.currentDate, -1)));
  byId("goToToday").addEventListener("click", () => changeDate(serverNow().date));
  byId("nextDay").addEventListener("click", () => changeDate(shiftDate(state.currentDate, 1)));
  byId("datePickerButton").addEventListener("click", () => byId("workDate").showPicker?.());
  byId("workDate").addEventListener("change", (event) => changeDate(event.target.value));
  byId("addBreak").addEventListener("click", () => addBreakRow());
  ["checkIn", "checkOut", "nextDayCheckout"].forEach((id) => byId(id).addEventListener("input", updateLiveSummary));
  byId("saveEntry").addEventListener("click", saveEntry);
  byId("checkInNow").addEventListener("click", () => timeAction("check-in"));
  byId("checkOutNow").addEventListener("click", () => timeAction("check-out"));
  byId("deleteDay").addEventListener("click", () => byId("deleteDialog").showModal());
  byId("confirmDelete").addEventListener("click", deleteDay);
  byId("vacationAction").addEventListener("click", openVacationDialog);
  byId("vacationForm").addEventListener("submit", saveVacation);
  byId("removeVacation").addEventListener("click", requestVacationRemoval);
  ["vacationStart", "vacationEnd"].forEach((id) => {
    byId(id).addEventListener("input", resetVacationRemovalConfirmation);
  });
  byId("vacationDialog").querySelectorAll(".close-vacation").forEach((button) => {
    button.addEventListener("click", () => {
      resetVacationRemovalConfirmation();
      byId("vacationDialog").close();
    });
  });
  byId("settingsButton").addEventListener("click", openSettings);
  byId("mobileSettingsButton").addEventListener("click", openSettings);
  byId("settingsForm").addEventListener("submit", saveSettings);
  byId("settingsDialog").querySelector(".close-modal").addEventListener("click", () => byId("settingsDialog").close());
  byId("deleteDialog").querySelector(".close-delete").addEventListener("click", () => byId("deleteDialog").close());
  byId("previousPeriod").addEventListener("click", () => shiftStatistics(-1));
  byId("nextPeriod").addEventListener("click", () => shiftStatistics(1));
  await Promise.all([loadEntry(), loadWeekSummary()]);
  setInterval(updateLiveSummary, 60_000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) updateLiveSummary(); });
  switchView(location.hash === "#statistics" ? "statistics" : "tracker");
}

if (typeof document !== "undefined" && document.getElementById("app")) {
  initialize().catch((error) => showToast(error.message));
}
