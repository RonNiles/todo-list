// Pure calendar/timezone math for recurring series, with no I/O and no env access —
// every function takes instants and a `tz` explicitly, so this can be checked with a
// throwaway script before ever touching a deploy.

// Wall-clock fields for `instant` as seen in `tz`.
export function localParts(instant, tz) {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const p = Object.fromEntries(dtf.formatToParts(instant).map((x) => [x.type, x.value]));
  return {
    year: +p.year, month: +p.month, day: +p.day,
    hour: +p.hour, minute: +p.minute, second: +p.second,
  };
}

// Minutes such that local = UTC + offset, at this instant, in this zone.
function tzOffsetMinutes(instant, tz) {
  const p = localParts(instant, tz);
  const asUTC = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return (asUTC - instant.getTime()) / 60000;
}

// Wall-clock (year, month 1-12, day, hour, minute) in `tz` -> the UTC instant it names.
// Standard "format a guess, diff, correct" convergence — handles DST transitions.
export function zonedTimeToUtc(year, month, day, hour, minute, tz) {
  let guessMs = Date.UTC(year, month - 1, day, hour, minute, 0);
  for (let i = 0; i < 2; i++) {
    const offset = tzOffsetMinutes(new Date(guessMs), tz);
    const corrected = Date.UTC(year, month - 1, day, hour, minute, 0) - offset * 60000;
    if (corrected === guessMs) break;
    guessMs = corrected;
  }
  return new Date(guessMs);
}

export function daysInMonth(year, month /* 1-12 */) {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function clampDayOfMonth(year, month, day) {
  return Math.min(day, daysInMonth(year, month));
}

export function addMonths(year, month, n) {
  const total = (month - 1) + n;
  const y = year + Math.floor(total / 12);
  const m = ((total % 12) + 12) % 12 + 1;
  return { year: y, month: m };
}

// Soonest cron occurrence (dayOfMonth/hour/minute, clamped for short months) at/after `atOrAfter`.
export function soonestCronOccurrence(dayOfMonth, hour, minute, tz, atOrAfter) {
  let { year, month } = localParts(atOrAfter, tz);
  for (let i = 0; i < 3; i++) {
    const day = clampDayOfMonth(year, month, dayOfMonth);
    const occ = zonedTimeToUtc(year, month, day, hour, minute, tz);
    if (occ.getTime() >= atOrAfter.getTime()) return occ;
    ({ year, month } = addMonths(year, month, 1));
  }
  throw new Error("soonestCronOccurrence: did not converge");
}

// The occurrence exactly `monthsAhead` calendar months from `fromInstant`'s own month —
// used to seed an explicit first due date (e.g. "I know this one isn't due for 2 months"),
// bypassing the "soonest at/after now" search soonestCronOccurrence does.
export function nthMonthOccurrence(fromInstant, monthsAhead, dayOfMonth, hour, minute, tz) {
  const { year, month } = localParts(fromInstant, tz);
  const { year: y2, month: m2 } = addMonths(year, month, monthsAhead);
  const day = clampDayOfMonth(y2, m2, dayOfMonth);
  return zonedTimeToUtc(y2, m2, day, hour, minute, tz);
}

// `prevOccurrence` advanced by `intervalMonths`, anchored to prevOccurrence's own calendar
// month (not "now") so the schedule never drifts.
export function advanceCronOccurrence(prevOccurrence, dayOfMonth, intervalMonths, hour, minute, tz) {
  const { year, month } = localParts(prevOccurrence, tz);
  const { year: y2, month: m2 } = addMonths(year, month, intervalMonths);
  const day = clampDayOfMonth(y2, m2, dayOfMonth);
  return zonedTimeToUtc(y2, m2, day, hour, minute, tz);
}

// `instant` + `days` calendar days, at an explicit local hour/minute (not the instant's own).
// Re-derives the local wall-clock date and reconverges through zonedTimeToUtc rather than
// adding days*86400000ms, so a DST transition inside the window doesn't shift the result.
export function addLocalDaysAt(instant, days, hour, minute, tz) {
  const p = localParts(instant, tz);
  const rolled = new Date(Date.UTC(p.year, p.month - 1, p.day + days, 0, 0, 0));
  return zonedTimeToUtc(rolled.getUTCFullYear(), rolled.getUTCMonth() + 1, rolled.getUTCDate(), hour, minute, tz);
}

// Same, but preserving `instant`'s own local time-of-day instead of a fixed one.
export function addLocalDays(instant, days, tz) {
  const p = localParts(instant, tz);
  return addLocalDaysAt(instant, days, p.hour, p.minute, tz);
}

// ---- pure trigger decisions (no I/O; `trackedTodo` is plain data or null) ----

// series: {nextDueAt, dayOfMonth, intervalMonths, hour, minute, tz}
// Returns null if not due yet, else {spawnRemindAt: Date, newNextDueAt: Date, supersede: boolean}.
export function decideCronTrigger(series, nowMs, trackedTodo) {
  if (new Date(series.nextDueAt).getTime() > nowMs) return null;

  let last = new Date(series.nextDueAt);
  let next = advanceCronOccurrence(last, series.dayOfMonth, series.intervalMonths, series.hour, series.minute, series.tz);
  while (next.getTime() <= nowMs) {
    last = next;
    next = advanceCronOccurrence(next, series.dayOfMonth, series.intervalMonths, series.hour, series.minute, series.tz);
  }

  const supersede = !!trackedTodo && !trackedTodo.done && !trackedTodo.cancelled;
  return { spawnRemindAt: last, newNextDueAt: next, supersede };
}

// series: {afterDays, tz, firstInDays?, hour?, minute?}
// Returns null if the tracked instance is still open, else {spawnRemindAt: Date, supersede: false}.
//
// `firstInDays`, when set, only ever applies to the very first instance (trackedTodo is
// null) — it overrides the normal "afterDays from the anchor" gap for cases where the real
// world is already partway through a cycle (e.g. a battery with only 2 days of charge left,
// on a series that otherwise re-checks every 8 days after each completion).
//
// `hour`/`minute`, when set, fix every occurrence's time-of-day (first and subsequent alike)
// instead of the default of inheriting whatever time the anchoring event happened to occur at
// — without this, a series completed once at 11pm keeps firing at 11pm forever.
export function decideAfterTrigger(series, nowMs, trackedTodo) {
  if (trackedTodo && !trackedTodo.done && !trackedTodo.cancelled) return null;

  const gap = (!trackedTodo && Number.isInteger(series.firstInDays)) ? series.firstInDays : series.afterDays;
  const anchor = !trackedTodo ? new Date(nowMs)
    : trackedTodo.done ? new Date(trackedTodo.doneAt)
    : new Date(trackedTodo.cancelledAt);

  const spawnRemindAt = Number.isInteger(series.hour)
    ? addLocalDaysAt(anchor, gap, series.hour, Number.isInteger(series.minute) ? series.minute : 0, series.tz)
    : addLocalDays(anchor, gap, series.tz);

  return { spawnRemindAt, supersede: false };
}
