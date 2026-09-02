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
    task: "", startTime: "", projectId: 0, projectName: "", clientName: ""
  }
  if (!raw) return fallback
  try {
    var parsed = JSON.parse(raw)
    return {
      text: typeof parsed.text === "string" ? parsed.text : "",
      tooltip: typeof parsed.tooltip === "string" ? parsed.tooltip : fallback.tooltip,
      class: typeof parsed.class === "string" ? parsed.class : "idle",
      task: typeof parsed.task === "string" ? parsed.task : "",
      startTime: typeof parsed.startTime === "string" ? parsed.startTime : "",
      projectId: typeof parsed.projectId === "number" ? parsed.projectId : 0,
      projectName: typeof parsed.projectName === "string" ? parsed.projectName : "",
      clientName: typeof parsed.clientName === "string" ? parsed.clientName : ""
    }
  } catch (e) {
    return fallback
  }
}

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

// "H:MM:SS", matching notch's own model.FormatDuration so the bar/popout
// never disagrees with the TUI's own formatting.
function formatSeconds(totalSeconds) {
  var s = Math.max(0, Math.floor(Number(totalSeconds) || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
}
