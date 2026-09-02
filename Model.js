// Parsing helpers for the "notch status -json" / "notch projects -json"
// output, kept out of BarWidget.qml the same way every first-party panel
// (e.g. shell/plugins/panels/weather/Model.js) keeps its parsing separate
// from layout. Both parsers fail closed to a safe default rather than
// throwing, since they run on whatever a Process happened to print (an
// unbuilt/old notch binary, a transient empty stdout on process spawn, etc).

.pragma library

function parseStatus(raw) {
  var fallback = { text: "", tooltip: "No timer running", class: "idle" }
  if (!raw) return fallback
  try {
    var parsed = JSON.parse(raw)
    return {
      text: typeof parsed.text === "string" ? parsed.text : "",
      tooltip: typeof parsed.tooltip === "string" ? parsed.tooltip : fallback.tooltip,
      class: typeof parsed.class === "string" ? parsed.class : "idle"
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
