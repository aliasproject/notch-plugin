// Parsing/formatting helpers for the "notch status -json" / "notch
// projects -json" output, kept out of BarWidget.qml the same way every
// first-party panel (e.g. shell/plugins/panels/weather/Model.js) keeps its
// parsing separate from layout. Both parsers fail closed to a safe default
// rather than throwing, since they run on whatever a Process happened to
// print (an unbuilt/old notch binary, a transient empty stdout on process
// spawn, etc).

.pragma library

function parseStatus(raw) {
  var fallback = {
    text: "", tooltip: "No timer running", class: "idle",
    task: "", notes: "", startTime: "", projectId: 0, projectName: "", clientName: ""
  }
  if (!raw) return fallback
  try {
    var parsed = JSON.parse(raw)
    return {
      text: typeof parsed.text === "string" ? parsed.text : "",
      tooltip: typeof parsed.tooltip === "string" ? parsed.tooltip : fallback.tooltip,
      class: typeof parsed.class === "string" ? parsed.class : "idle",
      task: typeof parsed.task === "string" ? parsed.task : "",
      notes: typeof parsed.notes === "string" ? parsed.notes : "",
      startTime: typeof parsed.startTime === "string" ? parsed.startTime : "",
      projectId: typeof parsed.projectId === "number" ? parsed.projectId : 0,
      projectName: typeof parsed.projectName === "string" ? parsed.projectName : "",
      clientName: typeof parsed.clientName === "string" ? parsed.clientName : ""
    }
  } catch (e) {
    return fallback
  }
}

// "notch projects -json" -- every project, for the "add a timer" picker
// (which needs to offer projects that have no recent-task history yet,
// unlike the recency-ordered list "notch tasks -json" drives).
function parseProjects(raw) {
  if (!raw) return []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(p) {
      return p && typeof p.id === "number" && typeof p.name === "string"
    })
  } catch (e) {
    return []
  }
}

// "notch clients -json" -- for the Add Timer form's client picker, which
// narrows the project picker to that client's own projects (see notch's
// TUI: task, then client, then project).
function parseClients(raw) {
  if (!raw) return []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(c) {
      return c && typeof c.id === "number" && typeof c.name === "string"
    })
  } catch (e) {
    return []
  }
}

function parseTasks(raw) {
  if (!raw) return []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(t) {
      return t && typeof t.projectId === "number" && typeof t.projectName === "string"
    })
  } catch (e) {
    return []
  }
}

// "notch summary -json" -- today's and this week's finished-entry totals.
// null (not zeros) when unavailable, e.g. a notch older than the summary
// command: that falls through to launching the TUI, which fails with no
// TTY and prints nothing on stdout, and the popout hides the totals row
// rather than showing a misleading 0:00:00.
function parseSummary(raw) {
  if (!raw) return null
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed.todaySeconds !== "number" || typeof parsed.weekSeconds !== "number") return null
    return { todaySeconds: parsed.todaySeconds, weekSeconds: parsed.weekSeconds }
  } catch (e) {
    return null
  }
}

// Quick-add's live filter over the recent-timers list: a case-insensitive
// substring match on task, project, or client, so typing a name you've
// used before surfaces the existing row to restart instead of creating a
// duplicate on Uncategorized.
function filterTasks(tasks, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return tasks
  return tasks.filter(function(t) {
    return (t.task || "").toLowerCase().indexOf(q) !== -1
      || (t.projectName || "").toLowerCase().indexOf(q) !== -1
      || (t.clientName || "").toLowerCase().indexOf(q) !== -1
  })
}

// Local midnight today / on this week's Monday, in ms -- the same
// boundaries notch's status.StartOfDay/StartOfWeek use, so the running
// entry's live contribution is clipped exactly where the finished-entry
// totals from "notch summary" are.
function startOfDayMs(nowMs) {
  var d = new Date(nowMs)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function startOfWeekMs(nowMs) {
  var d = new Date(startOfDayMs(nowMs))
  var weekday = d.getDay() === 0 ? 7 : d.getDay()
  d.setDate(d.getDate() - (weekday - 1))
  return d.getTime()
}

// Identity of one recent-timers row: notch groups entries by exact
// (project, task), so that pair is the key everywhere -- pinning, stable
// ordering, and which row is expanded. NUL can't appear in either part.
function taskKey(t) {
  return t.projectId + "\u0000" + t.task
}

// "notch entries -json" -- one task's sessions, newest first.
function parseEntries(raw) {
  if (!raw) return []
  try {
    var parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(function(e) {
      return e && typeof e.id === "number" && typeof e.startTime === "string"
    })
  } catch (e) {
    return []
  }
}

var _weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var _months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function _clock(d) {
  var h = d.getHours() % 12 || 12
  var m = d.getMinutes()
  return h + ":" + (m < 10 ? "0" : "") + m
}

function _meridiem(d) {
  return d.getHours() < 12 ? "AM" : "PM"
}

// A session's "when": "Today 9:00–9:40 AM", "Yesterday 4:50 PM–12:10 AM",
// "Mon Sep 22 9:00–9:40 AM", or "Today 9:00 AM–now" while running. The
// meridiem is written once when both ends share it.
function formatSessionLabel(startIso, endIso, nowMs) {
  var start = new Date(startIso)
  if (isNaN(start.getTime())) return ""
  var dayMs = startOfDayMs(start.getTime())
  var todayMs = startOfDayMs(nowMs)
  var day
  if (dayMs === todayMs) day = "Today"
  else if (dayMs === startOfDayMs(todayMs - 1)) day = "Yesterday"
  else day = _weekdays[start.getDay()] + " " + _months[start.getMonth()] + " " + start.getDate()

  if (!endIso) return day + " " + _clock(start) + " " + _meridiem(start) + "–now"
  var end = new Date(endIso)
  if (isNaN(end.getTime())) return day + " " + _clock(start) + " " + _meridiem(start)
  if (_meridiem(start) === _meridiem(end))
    return day + " " + _clock(start) + "–" + _clock(end) + " " + _meridiem(end)
  return day + " " + _clock(start) + " " + _meridiem(start) + "–" + _clock(end) + " " + _meridiem(end)
}

// A session's start or end as typed into the edit form: "9", "9:05",
// "905", "9:05pm", "9:05 PM", "21:05". Returns ms on the local day that
// dayStartMs begins, or NaN if unreadable. Without am/pm, 1-12 is taken
// as written (so "9" is 9 AM) -- the form pre-fills with AM/PM anyway.
function parseClockTime(text, dayStartMs) {
  var m = String(text || "").trim().toLowerCase().match(/^(\d{1,2})(?::?(\d{2}))?\s*(a|am|p|pm)?$/)
  if (!m) return NaN
  var h = parseInt(m[1], 10)
  var min = m[2] ? parseInt(m[2], 10) : 0
  var ampm = m[3] ? m[3][0] : ""
  if (min > 59) return NaN
  if (ampm) {
    if (h < 1 || h > 12) return NaN
    if (h === 12) h = 0
    if (ampm === "p") h += 12
  } else if (h > 23) {
    return NaN
  }
  var d = new Date(dayStartMs)
  d.setHours(h, min, 0, 0)
  return d.getTime()
}

// "9:05 AM" -- how the edit form pre-fills a session's times.
function formatClockTime(ms) {
  var d = new Date(ms)
  return _clock(d) + " " + _meridiem(d)
}

// RFC3339 without milliseconds, for "notch edit --start/--end".
function toRfc3339(ms) {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z")
}

// A task row's billing summary from "tasks -json"'s counts: "" when none
// is invoiced, "paid"/"invoiced" when all are, else "2/3 invoiced" (paid
// counts as invoiced -- notch only allows paid on an invoiced entry).
function billingLabel(t) {
  var n = t.entryCount || 0
  var inv = t.invoicedCount || 0
  var paid = t.paidCount || 0
  if (n === 0 || inv === 0) return ""
  if (paid === n) return "paid"
  if (inv === n) return "invoiced"
  return inv + "/" + n + " invoiced"
}

// Re-applies a fresh "notch tasks -json" response onto the currently
// displayed row order instead of just replacing it outright. The server
// always sorts by most-recent-use, so a plain replace reshuffles the whole
// list -- including rows that didn't change at all -- every time a
// start/stop refresh lands while the popout is open (starting or stopping
// a task changes exactly its own recency, which is enough to move it,
// which shifts every row after it). This keeps each row's position fixed
// once shown, refreshing only its data in place; rows the server dropped
// (aged out of its own limit) are simply left off, and any row the server
// reports that wasn't already on screen is appended at the end. Call this
// for refreshes that happen *while already open* -- use the raw parsed
// list instead (a real re-sort) when the popout freshly opens, so it's
// still accurate whenever you deliberately go look at it.
function reorderTasksInPlace(previous, incoming) {
  var key = taskKey
  var incomingByKey = {}
  for (var i = 0; i < incoming.length; i++) incomingByKey[key(incoming[i])] = incoming[i]

  var seen = {}
  var merged = []
  for (var j = 0; j < previous.length; j++) {
    var k = key(previous[j])
    if (incomingByKey.hasOwnProperty(k)) {
      merged.push(incomingByKey[k])
      seen[k] = true
    }
  }
  for (var m = 0; m < incoming.length; m++) {
    var k2 = key(incoming[m])
    if (!seen[k2]) merged.push(incoming[m])
  }
  return merged
}

// "H:MM:SS", matching notch's own model.FormatDuration so the bar/popout
// never disagrees with the TUI's own formatting.
function formatSeconds(totalSeconds) {
  var s = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
}
