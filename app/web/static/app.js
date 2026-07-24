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
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
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
  const today = localISODate();
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
      values.innerHTML = `<input class="break-start" type="text" inputmode="decimal" aria-label="Break start" placeholder="12:00" value="${escapeHtml(item.start ?? "")}"><input class="break-end" type="text" inputmode="decimal" aria-label="Break end" placeholder="12:30" value="${escapeHtml(item.end ?? "")}">`;
    }
    values.querySelectorAll("input").forEach((input) => input.addEventListener("input", updateLiveSummary));
  };
  mode.addEventListener("change", () => {
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
      return { mode, duration_minutes: Number(row.querySelector(".break-duration").value) };
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
    check_in: byId("checkIn").value.trim() || null,
    check_out: byId("checkOut").value.trim() || null,
    check_out_next_day: byId("nextDayCheckout").checked,
    breaks: collectBreaks(),
    notes: byId("notes").value,
  };
}

function updateLiveSummary() {
  try {
    const draft = collectDraft();
    const calculated = calculateDraft({
      checkIn: draft.check_in,
      checkOut: draft.check_out,
      nextDay: draft.check_out_next_day,
      breaks: draft.breaks,
      rounding: state.preferences.rounding_minutes,
    });
    byId("billableHours").textContent = calculated.billable == null
      ? "—"
      : (calculated.billable / 60).toFixed(2);
    byId("exactDuration").textContent = formatDuration(calculated.exact);
    byId("breakDuration").textContent = calculated.breakMinutes
      ? formatDuration(calculated.breakMinutes)
      : "0 min";
    const increment = state.preferences.rounding_minutes;
    byId("roundingDescription").textContent = increment === 1 ? "No rounding" : `Next ${increment} min`;
    showFormError();
  } catch (error) {
    byId("billableHours").textContent = "—";
    byId("exactDuration").textContent = "—";
    showFormError(error.message);
  }
}

function renderEntry(entry) {
  state.entry = entry;
  byId("checkIn").value = entry.check_in || "";
  byId("checkOut").value = entry.check_out || "";
  byId("nextDayCheckout").checked = entry.check_out_next_day;
  byId("notes").value = entry.notes || "";
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
  await loadEntry();
}

async function saveEntry() {
  const button = byId("saveEntry");
  button.disabled = true;
  showFormError();
  try {
    renderEntry(await api(`/entries/${state.currentDate}`, {
      method: "PUT",
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

async function timeAction(action) {
  showFormError();
  try {
    renderEntry(await api(`/entries/${state.currentDate}/${action}`, { method: "POST" }));
    showToast(action === "check-in" ? "Checked in." : "Checked out.");
    await loadWeekSummary();
  } catch (error) {
    showFormError(error.message);
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
  const summary = data.summary;
  byId("weekTotal").textContent = `${formatDuration(summary.exact_minutes, { decimal: true })} / ${formatDuration(summary.target_minutes, { decimal: true })}`;
  byId("weekBalance").textContent = formatDuration(summary.balance_minutes, { signed: true, decimal: true });
  byId("weekBalance").className = `balance-badge ${summary.balance_minutes > 0 ? "is-positive" : summary.balance_minutes < 0 ? "is-negative" : ""}`;
  byId("weekProgress").style.width = `${Math.min(100, summary.completion_percent)}%`;
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
    return `<div class="${classes}"><div><i>${letter}</i><span>${new Intl.DateTimeFormat("en", { weekday: "short", day: "2-digit" }).format(date)}${vacation}</span></div><strong>${day.exact_minutes ? formatDuration(day.exact_minutes, { decimal: true }) : "—"}</strong></div>`;
  }).join("");
}

async function loadWeekSummary() {
  try {
    renderWeekSummary(await api(`/statistics?period=week&anchor=${state.currentDate}`));
  } catch (error) {
    showToast(error.message);
  }
}

function renderStatistics(data) {
  const summary = data.summary;
  const start = dateFromISO(data.start);
  const end = dateFromISO(data.end);
  const dateFormat = new Intl.DateTimeFormat("en", { day: "2-digit", month: "short", year: "numeric" });
  byId("statisticsRange").textContent = `${dateFormat.format(start)} – ${dateFormat.format(end)}`;
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

  const maximum = Math.max(1, ...data.weeks.flatMap((week) => [week.exact_minutes, week.target_minutes]));
  byId("weeklyChart").innerHTML = data.weeks.map((week) => {
    const weekDate = dateFromISO(week.week_start);
    return `<div class="chart-column" title="${formatDuration(week.exact_minutes)} actual · ${formatDuration(week.target_minutes)} target"><div class="chart-bars"><span class="chart-bar" style="height:${Math.max(2, week.exact_minutes / maximum * 100)}%"></span><span class="chart-bar target" style="height:${Math.max(2, week.target_minutes / maximum * 100)}%"></span></div><small>${weekDate.getDate()} ${weekDate.toLocaleString("en", { month: "short" })}</small></div>`;
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
    renderStatistics(await api(`/statistics?period=${state.period}&anchor=${state.statisticsAnchor}`));
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
  [state.meta, state.preferences] = await Promise.all([api("/meta"), api("/preferences")]);
  byId("federalState").innerHTML = Object.entries(state.meta.federal_states)
    .map(([code, name]) => `<option value="${code}">${escapeHtml(name)}</option>`).join("");
  document.querySelectorAll("[data-view]").forEach((button) => button.addEventListener("click", () => switchView(button.dataset.view)));
  document.querySelectorAll("[data-period]").forEach((button) => button.addEventListener("click", () => {
    state.period = button.dataset.period;
    document.querySelectorAll("[data-period]").forEach((item) => item.classList.toggle("is-active", item === button));
    loadStatistics();
  }));
  byId("previousDay").addEventListener("click", () => changeDate(shiftDate(state.currentDate, -1)));
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
  switchView(location.hash === "#statistics" ? "statistics" : "tracker");
}

if (typeof document !== "undefined" && document.getElementById("app")) {
  initialize().catch((error) => showToast(error.message));
}
