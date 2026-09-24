import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar-widget entry point for the notch plugin (see manifest.json). One
// Panel-rooted file is both the bar icon and its popout, the same
// self-contained shape shell/plugins/panels/weather/Panel.qml and
// shell/plugins/panels/power/Panel.qml use — base Panel.qml's own
// open()/close()/toggle()/opened already give a bar-widget everything
// the shell needs to route clicks/IPC to it.
//
// notch itself has no daemon: every action here is a one-shot CLI call
// ("notch status/tasks/start/stop -json") that opens the sqlite db, does
// one thing, and exits — see notch's README "Scripting" section.
// The popout's hero clock and the active task row's running time tick
// locally between polls (from the "startTime" the status JSON reports),
// rather than re-spawning notch every second, for a smooth live readout.
Panel {
  id: root
  moduleName: "io.github.aliasproject.notch"
  ipcTarget: "io.github.aliasproject.notch"

  property string statusText: ""
  property string statusTooltip: "No timer running"
  property string statusClass: "idle"
  property string statusTask: ""
  property string statusNotes: ""
  property string statusStartTime: ""
  property int statusProjectId: 0
  property string statusProjectName: ""
  property string statusClientName: ""
  property var recentTasks: []
  property var allProjects: []
  property var allClients: []
  // Klokki-style quick add: "+" inserts one editable row (styled like a
  // real timer row) at the top of the list, cursor already in the task
  // field -- type a name, Enter, done. No client/project decision up
  // front; it starts on notch's own "Uncategorized/General" catch-all
  // (db.EnsureUncategorizedProject, reached here via "notch start --task
  // ..." with no --project/--client-name/--project-name at all). Assigning
  // a real client/project happens after the fact, via editingTimer below.
  property bool quickAdding: false

  // Editing the *currently running* entry's client/project/task/notes --
  // "notch edit" (defaults to the running entry when no --id is given).
  // Pre-filled from the live status when opened. Same free-text-with-
  // suggestions shape as the old up-front new-timer form used to be
  // (NameField, resolve-existing-or-create server-side), just applied to
  // an existing entry instead of a new one.
  property bool editingTimer: false
  property string editTaskText: ""
  property string editClientText: ""
  property string editProjectText: ""
  property string editNotesText: ""
  property real nowMs: Date.now()
  // true right before a refresh that should re-sort to the server's true
  // recency order (a fresh open); false for a refresh triggered by a
  // start/stop action while already open, which should keep the on-screen
  // row order fixed instead -- see Model.reorderTasksInPlace.
  property bool tasksNeedFreshSort: true
  // Set right before an action-triggered refreshStatus(); consumed once
  // that status refresh actually lands, which is what then fires
  // refreshTasks() -- see statusProc and actionProc below for why this
  // can't just be two independent calls.
  property bool tasksRefreshPending: false
  // The most recently started task's "projectId task" key, kept even
  // after it stops -- see displayedTasks. Reset on a fresh open (in
  // onOpenedChanged), so a session doesn't keep artificially pinning
  // something from a previous visit once the popout's been closed.
  property string lastActiveKey: ""

  // "notch summary -json" -- finished-entry totals only; the running
  // entry's share is added live below (todaySeconds/weekSeconds).
  // summaryAvailable stays false on a notch that predates the command, and
  // the totals row stays hidden instead of claiming 0:00:00.
  property bool summaryAvailable: false
  property int summaryTodaySeconds: 0
  property int summaryWeekSeconds: 0

  // false once "notch status" has exited non-zero (missing binary, broken
  // DB) -- the hero says so instead of looking like a plain idle state.
  property bool notchAvailable: true
  // Last failed start/stop/edit's stderr, shown under the hero until the
  // next action or errorClearTimer. Those calls used to fail silently.
  property string lastError: ""

  // Keyboard cursor over visibleTasks, the same cursorActive/selectedIndex
  // shape the first-party bluetooth panel uses: nothing is highlighted
  // until the first arrow/j/k press (or a hover), so opening the popout
  // doesn't paint a stray highlight on row 0.
  property bool cursorActive: false
  property int selectedIndex: 0
  // Quick-add's typed text, mirrored out of quickAddField so visibleTasks
  // can filter the list on it -- see Model.filterTasks.
  property string quickAddQuery: ""
  // "Discard timer" confirmation (ConfirmDialog over the popout). Discard
  // deletes the running entry outright via "notch delete" -- for an
  // accidental start, where stopping would leave a stray short entry.
  property bool discardConfirmOpen: false
  // Pointer over the hero row -- the other place Delete discards from.
  property bool heroHovered: false

  readonly property bool running: statusClass === "running"
  readonly property real startTimeMs: statusStartTime !== "" ? Date.parse(statusStartTime) : 0
  readonly property int elapsedSeconds: running && startTimeMs > 0
    ? Math.max(0, Math.floor((nowMs - startTimeMs) / 1000))
    : 0

  readonly property string heroTimeText: Model.formatSeconds(elapsedSeconds)
  readonly property string heroTaskText: {
    if (!notchAvailable) return "notch isn't responding"
    if (running) return statusTask !== "" ? statusTask : statusProjectName
    return "No timer running"
  }
  readonly property string heroMetaText: {
    if (!notchAvailable) return "Check that notch is on your PATH"
    if (running) return statusClientName + " › " + statusProjectName
    if (resumeTask) return "Last: " + (resumeTask.task !== "" ? resumeTask.task : resumeTask.projectName)
    return ""
  }

  // What the hero's play button restarts while idle: the most recent task,
  // i.e. the top of the list (which a fresh open sorts by recency, and
  // displayedTasks keeps pinned there after a stop).
  readonly property var resumeTask: !running && displayedTasks.length > 0 ? displayedTasks[0] : null

  // Today / this week, ticking live: summary's finished totals plus the
  // running entry's elapsed time since each period began (clipped the
  // same way notch's status.Summarize clips finished entries).
  function _runningSecondsSince(periodStartMs) {
    if (!running || startTimeMs <= 0) return 0
    return Math.max(0, Math.floor((nowMs - Math.max(startTimeMs, periodStartMs)) / 1000))
  }
  readonly property int todaySeconds: summaryTodaySeconds + _runningSecondsSince(Model.startOfDayMs(nowMs))
  readonly property int weekSeconds: summaryWeekSeconds + _runningSecondsSince(Model.startOfWeekMs(nowMs))

  // What the list actually renders. "notch tasks -json" only reports
  // *finished* entries (see notch's ListRecentTasks), so a task started
  // just now -- even one that's been done before -- doesn't appear in
  // recentTasks at all until it's stopped. This pins whichever task is
  // currently running (or, once stopped, whichever ran most recently this
  // session -- lastActiveKey) to the front for display, pulling its
  // existing row (with its real prior total) up if it has one, or
  // synthesizing one at 0 total if it doesn't.
  //
  // Pinning by lastActiveKey continues *after* the task stops, not just
  // while running: restarting an old, further-down task moves it to the
  // top immediately (the running-only case), but it's still genuinely the
  // most-recently-used task the moment you stop it too -- reverting to
  // wherever Model.reorderTasksInPlace's stable merge happened to leave it
  // (its old, pre-restart position) would hide the one piece of reordering
  // that's actually correct, not just incidental churn. Everything *else*
  // in the list still keeps its stable order.
  readonly property var displayedTasks: {
    var pinKey = running ? (statusProjectId + " " + statusTask) : lastActiveKey
    if (pinKey === "") return recentTasks
    var pinnedEntry = null
    var rest = []
    for (var i = 0; i < recentTasks.length; i++) {
      var t = recentTasks[i]
      if (!pinnedEntry && (t.projectId + " " + t.task) === pinKey) pinnedEntry = t
      else rest.push(t)
    }
    if (!pinnedEntry) {
      // Nothing to pin (e.g. a stale lastActiveKey the tasks list no
      // longer has, or the server hasn't reported the finished entry
      // back yet) -- if we're not even running, there's nothing to
      // synthesize either, so just show the list as-is.
      if (!running) return recentTasks
      pinnedEntry = {
        projectId: statusProjectId, projectName: statusProjectName,
        clientName: statusClientName, task: statusTask, totalSeconds: 0
      }
    }
    return [pinnedEntry].concat(rest)
  }

  // displayedTasks narrowed by whatever's typed into quick add -- the
  // Repeater and the keyboard cursor both index into this, never into
  // displayedTasks directly.
  readonly property var visibleTasks: quickAdding
    ? Model.filterTasks(displayedTasks, quickAddQuery)
    : displayedTasks

  onVisibleTasksChanged: {
    if (selectedIndex > visibleTasks.length - 1) selectedIndex = Math.max(0, visibleTasks.length - 1)
    if (visibleTasks.length === 0) cursorActive = false
  }

  function isTaskActive(t) {
    return running && t.projectId === statusProjectId && t.task === statusTask
  }

  // One row's click/Enter: stop it if it's the one running, else start it.
  function toggleTask(t) {
    if (!t) return
    if (isTaskActive(t)) stopTimer()
    else startTask(t.projectId, t.task)
  }

  // The hero button, and Space with no row selected: stop what's running,
  // or pick the last task back up.
  function heroAction() {
    if (running) stopTimer()
    else if (resumeTask) startTask(resumeTask.projectId, resumeTask.task)
  }

  function moveCursor(dy) {
    if (visibleTasks.length === 0) return
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = dy < 0 ? visibleTasks.length - 1 : 0
      return
    }
    selectedIndex = Math.max(0, Math.min(visibleTasks.length - 1, selectedIndex + dy))
  }

  // Edit form's project field suggestion pool, narrowed to whichever
  // client is currently typed IF it exactly (case-insensitively) matches
  // an existing client -- picking a real client actually shrinks the
  // project list. A new (not-yet-existing) or blank client can't scope
  // anything yet, so every project is offered instead of none.
  readonly property var editMatchedClient: {
    var q = editClientText.trim().toLowerCase()
    if (q === "") return null
    for (var i = 0; i < allClients.length; i++) {
      if (allClients[i].name.toLowerCase() === q) return allClients[i]
    }
    return null
  }
  readonly property var editProjectOptions: editMatchedClient
    ? allProjects.filter(function(p) { return p.clientId === editMatchedClient.id })
    : allProjects

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshTasks() {
    if (!tasksProc.running) tasksProc.running = true
  }

  function refreshProjects() {
    if (!projectsProc.running) projectsProc.running = true
  }

  function refreshClients() {
    if (!clientsProc.running) clientsProc.running = true
  }

  function refreshSummary() {
    if (!summaryProc.running) summaryProc.running = true
  }

  // Every mutating call goes through here so a failure is reported the
  // same way regardless of which button triggered it.
  function runAction(cmd) {
    if (actionProc.running) return
    lastError = ""
    actionProc.command = cmd
    actionProc.running = true
  }

  // Used by the recent-timers list, which already has a concrete project
  // ID for each row.
  function startTask(projectId, task, notes) {
    var cmd = ["notch", "start", "--project", String(projectId), "--task", task || ""]
    if (notes) cmd.push("--notes", notes)
    runAction(cmd)
  }

  // Used by the recent-timers list' quick-add row, which never specifies a
  // client/project -- notch resolves that to its own Uncategorized/General
  // catch-all (db.EnsureUncategorizedProject) when none of --project/
  // --client-name/--project-name are given at all.
  function startTaskByName(clientName, projectName, task, notes) {
    var cmd = ["notch", "start", "--task", task || ""]
    if (clientName) cmd.push("--client-name", clientName)
    if (projectName) cmd.push("--project-name", projectName)
    if (notes) cmd.push("--notes", notes)
    runAction(cmd)
  }

  // Quick add: "+" on the recent-timers list opens one inline, editable
  // row -- no client/project decision up front, just a task name and Enter.
  function openQuickAdd() {
    quickAdding = true
    // Imperative, not `text: root.quickAddTaskText` on the field itself --
    // see openEditTimer()'s own comment (same reasoning applies here: a
    // persistent binding gets silently severed by the field's own
    // onTextChanged the moment you type into it).
    quickAddField.text = ""
    quickAddQuery = ""
    cursorActive = false
    Qt.callLater(function() { quickAddField.forceActiveFocus() })
  }

  function cancelQuickAdd() {
    quickAdding = false
    quickAddQuery = ""
    cursorActive = false
  }

  // Enter in quick add: a row picked with the arrow keys restarts that
  // existing task (client/project and all); otherwise the typed text
  // starts a new one on Uncategorized, as before.
  function submitQuickAdd() {
    if (cursorActive && selectedIndex < visibleTasks.length) {
      var picked = visibleTasks[selectedIndex]
      cancelQuickAdd()
      toggleTask(picked)
      return
    }
    var task = quickAddField.text.trim()
    if (task === "") return
    startTaskByName("", "", task, "")
    cancelQuickAdd()
  }

  // Editing the *running* entry's client/project/task/notes -- "notch
  // edit" defaults to the running entry when no --id is given. Pre-fills
  // from the live status so e.g. re-submitting an unedited task/notes
  // field is a no-op, not a silent clear.
  function openEditTimer() {
    if (!running) return
    editingTimer = true
    editTaskText = statusTask
    editClientText = statusClientName
    editProjectText = statusProjectName
    editNotesText = statusNotes
    // Fields' own `text` is set imperatively here and nowhere else
    // declaratively: a plain `text: root.editXxxText` binding on the field
    // itself gets silently severed the moment its own onTextChanged
    // assigns back to root.editXxxText, which happens on every keystroke
    // -- after that, an external write (like this pre-fill, or the
    // project field's own "picking a project also fills in its client"
    // cross-write) would update state used at submit time without the
    // visible field ever showing it. This bit an earlier version of the
    // Add Timer form this replaced; see that bug's fix for the full story.
    editTaskField.text = statusTask
    editClientField.text = statusClientName
    editProjectField.text = statusProjectName
    editNotesField.text = statusNotes
    // Same Qt.callLater-after-becoming-visible idiom qs.Ui's own
    // SearchableDropdown uses to focus its search field on open. Client,
    // not Task: the task is usually already right (it's why you're
    // editing is almost always to assign a client/project after a quick
    // add), so that's the field actually worth landing in.
    Qt.callLater(function() { editClientField.focusField() })
  }

  function cancelEditTimer() {
    editingTimer = false
  }

  function submitEditTimer() {
    if (actionProc.running) return
    var cmd = ["notch", "edit"]
    var clientName = editClientText.trim()
    var projectName = editProjectText.trim()
    var task = editTaskText.trim()
    var notes = editNotesText.trim()
    if (clientName) cmd.push("--client-name", clientName)
    if (projectName) cmd.push("--project-name", projectName)
    if (task) cmd.push("--task", task)
    if (notes) cmd.push("--notes", notes)
    runAction(cmd)
    editingTimer = false
  }

  function stopTimer() {
    runAction(["notch", "stop"])
  }

  // Cancel is pre-selected (the clipboard plugin's clear-history confirm
  // defaults to its destructive button; this deletes tracked time, so a
  // reflexive Enter shouldn't be what does it).
  function openDiscardConfirm() {
    if (!running) return
    quickAdding = false
    editingTimer = false
    discardConfirm.selectedIndex = 0
    discardConfirmOpen = true
    Qt.callLater(function() { discardKeys.forceActiveFocus() })
  }

  function closeDiscardConfirm() {
    discardConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Delete over the running timer -- its row (hovered or arrow-selected)
  // or the hero -- asks to discard it. Anywhere else it's a no-op: other
  // rows aggregate a task's whole history, not one deletable entry.
  function deleteAtCursor() {
    if (!running) return
    var onActiveRow = cursorActive && selectedIndex < visibleTasks.length
      && isTaskActive(visibleTasks[selectedIndex])
    if (onActiveRow || heroHovered) openDiscardConfirm()
  }

  function discardTimer() {
    closeDiscardConfirm()
    if (running) runAction(["notch", "delete"])
  }

  // Floating terminal running the full TUI, for anything beyond a quick
  // start/stop (editing entries, reports, clients). xdg-terminal-exec is
  // the portable primitive here (not aliasOS's own aliasos-launch-tui
  // wrapper) so this works unmodified on stock Omarchy too.
  function openTui() {
    launchProc.command = ["xdg-terminal-exec", "--app-id=org.aliasproject.notch", "-e", "notch"]
    launchProc.running = true
  }

  onOpenedChanged: if (opened) {
    tasksNeedFreshSort = true
    lastActiveKey = ""
    cursorActive = false
    selectedIndex = 0
    refreshTasks()
    refreshProjects()
    refreshClients()
    refreshSummary()
  } else {
    cancelQuickAdd()
    editingTimer = false
    discardConfirmOpen = false
  }

  Process {
    id: statusProc
    command: ["notch", "status", "-json"]
    onExited: function(exitCode) { root.notchAvailable = exitCode === 0 }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        root.statusText = parsed.text
        root.statusTooltip = parsed.tooltip
        root.statusClass = parsed.class
        root.statusTask = parsed.task
        root.statusNotes = parsed.notes
        root.statusStartTime = parsed.startTime
        root.statusProjectId = parsed.projectId
        root.statusProjectName = parsed.projectName
        root.statusClientName = parsed.clientName
        if (parsed.class === "running") root.lastActiveKey = parsed.projectId + " " + parsed.task
        root.nowMs = Date.now()
        // Only after status has actually landed -- see
        // tasksRefreshPending's own comment for why this can't just be a
        // second independent call sitting next to refreshStatus().
        if (root.tasksRefreshPending) {
          root.tasksRefreshPending = false
          root.refreshTasks()
          root.refreshSummary()
        }
      }
    }
  }

  Process {
    id: tasksProc
    command: ["notch", "tasks", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var incoming = Model.parseTasks(text)
        root.recentTasks = root.tasksNeedFreshSort
          ? incoming
          : Model.reorderTasksInPlace(root.recentTasks, incoming)
        root.tasksNeedFreshSort = false
      }
    }
  }

  Process {
    id: projectsProc
    command: ["notch", "projects", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.allProjects = Model.parseProjects(text)
    }
  }

  Process {
    id: summaryProc
    command: ["notch", "summary", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseSummary(text)
        root.summaryAvailable = parsed !== null
        if (parsed) {
          root.summaryTodaySeconds = parsed.todaySeconds
          root.summaryWeekSeconds = parsed.weekSeconds
        }
      }
    }
  }

  Process {
    id: clientsProc
    command: ["notch", "clients", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.allClients = Model.parseClients(text)
    }
  }

  // Fire-and-forget: start/stop don't print anything worth reading, so
  // just re-poll status + totals once the process exits (whether it
  // succeeded or not -- a failed start/stop should still show the real
  // current state, not a stale optimistic one). tasksNeedFreshSort is left
  // false here, so this refresh updates each row's data in place without
  // re-sorting/shifting the list -- see Model.reorderTasksInPlace.
  //
  // refreshTasks() is deliberately NOT called directly here alongside
  // refreshStatus() -- they'd be two independent Processes racing each
  // other, and displayedTasks reads both root.running (from status) and
  // root.recentTasks (from tasks) together. If tasks happened to land
  // first after a stop, root.running would still read true for a moment
  // while recentTasks already reflected the finished entry -- fine. But
  // if status landed first (just as plausible), running flips to false
  // while recentTasks is still the pre-stop list, which never contained a
  // brand-new task at all (it only ever appeared via displayedTasks'
  // synthesized "pin the active one" entry, never in recentTasks itself)
  // -- so the row would vanish until the next refresh caught up, which
  // this Process's onExited never itself waits for or re-renders from.
  // tasksRefreshPending makes refreshTasks() fire only once status has
  // actually landed, so displayedTasks always reads a consistent pair.
  //
  // A non-zero exit surfaces notch's own stderr as lastError. Read via
  // Qt.callLater so the stderr collector has flushed by the time it's read.
  Process {
    id: actionProc
    stderr: StdioCollector { id: actionStderr }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        Qt.callLater(function() {
          var msg = (actionStderr.text || "").trim().split("\n")[0]
          root.lastError = msg !== "" ? msg : ("notch exited with code " + exitCode)
          errorClearTimer.restart()
        })
      }
      root.tasksRefreshPending = true
      root.refreshStatus()
    }
  }

  Timer {
    id: errorClearTimer
    interval: 8000
    onTriggered: root.lastError = ""
  }

  Process {
    id: launchProc
  }

  // Fast path for picking up a change made elsewhere -- the TUI, another
  // "notch" invocation, whatever -- instead of waiting on the slow poll
  // fallback below. An earlier version of this watched "<dbPath>-wal" via
  // FileView{watchChanges:true}: notch opens sqlite in WAL mode, so an
  // ordinary write lands there first. That turned out to self-trigger --
  // *every* notch invocation, reads included, opens/checkpoints/closes
  // that file (confirmed with inotifywait), so refreshStatus()'s own
  // "notch status -json"/"notch tasks -json" reads re-fired the same
  // watch that triggered them, an unbounded refresh loop rather than the
  // efficient push this was meant to be.
  //
  // QML/Quickshell has no SQLite binding, so unlike notch's own TUI (which
  // can hold a connection open and check PRAGMA data_version directly --
  // see internal/db/watch.go) this side can only shell out. "notch watch"
  // exists for exactly that: run once as a long-lived background process,
  // it holds its own persistent connection and does that same
  // data_version check, printing a line only on a genuine external write
  // and staying silent on reads -- including this plugin's own. Mirrors
  // Clipboard.qml's "wl-paste --watch" idiom: setpriv --pdeathsig TERM so
  // the child dies with the shell instead of orphaning, onExited restarts
  // it rather than leaving the fast path dead for the rest of the session.
  Process {
    id: dbWatchProc
    running: true
    command: ["setpriv", "--pdeathsig", "TERM", "notch", "watch"]
    onExited: dbWatchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(line) { dbChangeDebounce.restart() }
    }
  }

  Timer {
    id: dbWatchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!dbWatchProc.running) dbWatchProc.running = true
    }
  }

  // Coalesces a burst of "changed" lines (a start immediately followed by
  // a stop, say landing in separate debounce windows server-side) into one
  // refresh, same reasoning and duration as notch's own internal/db.Watch
  // debounce.
  Timer {
    id: dbChangeDebounce
    interval: 75
    onTriggered: {
      root.tasksRefreshPending = true
      root.refreshStatus()
    }
  }

  // Fallback only: dbWatchProc above is the fast, primary path. This just
  // guards against it having failed to start (e.g. notch not yet on PATH)
  // or missed an event, so a refresh still happens eventually rather than
  // never -- same "watch primary, slow poll fallback" split notch's own
  // TUI now uses (TickMsg's tickFallbackTicks vs dbWatchMsg).
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.tasksRefreshPending = true
      root.refreshStatus()
    }
  }

  // Live per-second tick for the bar label, hero clock, and the active
  // project row's running total -- only while a timer is actually
  // running, same as clock/Panel.qml's own always-on 1s timer.
  Timer {
    interval: 1000
    running: root.running
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // root is a plain Item (Panel.qml's base) with no implicit size of its
  // own -- every first-party bar item (system-update, weather, power)
  // binds implicitWidth/Height to its inner button explicitly, or the bar's
  // layout gives it zero size and it silently never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // WidgetButton, not BarIconButton: BarIconButton is a fixed icon-slot
  // square meant for single glyphs, and a running timer's live digits need
  // room a fixed slot can't give them. Neither state uses WidgetButton's
  // own built-in label (labelVisible stays false always) -- both render
  // their own OpticalGlyph/Text children instead, so the icon can carry
  // its own MouseArea (see below) without fighting WidgetButton's single
  // whole-button click region.
  //
  // The icon sits at the exact same position whether idle or running
  // (iconBox's left anchor/margin never change) -- only its glyph swaps
  // (md-timer <-> md-stop) and the time text next to it appears/disappears.
  // Deliberately no animation/Behavior on fixedWidth here: an earlier
  // version animated the width so DraggableRegion.qml's Flow would reflow
  // neighboring widgets smoothly, but combined with the icon being
  // re-centered as the button grew, it read as the icon vanishing and the
  // whole thing sliding in. Keeping the icon's position fixed removes the
  // need for that in the first place -- nothing in this widget visually
  // moves, so an instant width change no longer looks like a jump, just
  // the time appearing where there's now room for it.
  //
  // The glyph is the Nerd Font "md-timer"/"md-stop" PUA codepoints, not
  // plain Unicode characters -- those render noticeably smaller than every
  // sibling's purpose-built icon glyph even at the same Style.bar.iconFont
  // size, since they aren't part of the icon glyph set the rest of the bar
  // draws from.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    clip: true
    // Same left inset idle's centered icon already sits at (iconSlot is
    // wider than iconCanvas; centering one inside the other is this same
    // margin), reused here so iconBox's position is identical in both
    // fixedWidth branches -- that identity is what keeps the icon still.
    readonly property real iconInset: (Style.bar.iconSlot - Style.bar.iconCanvas) / 2
    fixedWidth: root.running
      ? (iconInset + Style.bar.iconCanvas + Style.space(6) + timeText.implicitWidth + iconInset)
      : Style.bar.iconSlot
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.statusTooltip
      + (root.summaryAvailable ? "\nToday " + Model.formatSeconds(root.todaySeconds) : "")
    // Whole-button fallback: catches the cross-widget popout-switch path
    // (KeyboardPanel's dismissArea calls triggerPress() directly on the
    // registered click target, bypassing normal hit-testing entirely) and
    // any click that isn't over the icon's own MouseArea below -- i.e. the
    // time digits when running.
    onPressed: root.toggle()

    Item {
      id: iconBox
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas
      anchors.left: parent.left
      anchors.leftMargin: button.iconInset
      anchors.verticalCenter: parent.verticalCenter

      OpticalGlyph {
        anchors.fill: parent
        // Stop, not pause: notch has no true pause/resume, only
        // start/stop -- this ends the running entry outright (same action
        // the popout's active row does), and there's no way to silently
        // resume the same entry later without a gap.
        text: root.running ? "󰓛" : "󱎫"
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.foreground
      }

      // Always live (not just while running): idle and running do the
      // same thing here anyway (toggle the popout), so there's no need to
      // conditionally swap this MouseArea in and out.
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.running ? root.stopTimer() : root.toggle()
      }
    }

    // Sibling of iconBox, not a child -- anchored to its right edge so it
    // simply appears/disappears next to a icon that never itself moves. No
    // MouseArea of its own: falls through to WidgetButton's onPressed
    // above, which opens the popout.
    //
    // Sized and rendered like WidgetButton's own built-in label (which the
    // clock widget uses for its time), not at Style.bar.iconFont: that
    // token is for icon glyphs, and digits at it read visibly larger than
    // the clock's digits sitting a few widgets over on the same bar.
    Text {
      id: timeText
      visible: root.running
      textFormat: Text.PlainText
      text: root.heroTimeText
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
      anchors.left: iconBox.right
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Popout anchor point, deliberately NOT `button` itself: KeyboardPanel
  // centers the popout under anchorItem's midpoint (anchorScreenPos.x +
  // anchorW/2), and button's own width/center still differ between idle
  // and running (fixedWidth above) even though the change is instant now,
  // not animated -- anchoring directly to button would still snap the open
  // popout sideways every time a timer starts or stops. button's *left*
  // edge never moves though -- nothing before this widget in
  // DraggableRegion.qml's Flow resizes, so only button's right edge shifts
  // as it grows/shrinks. This marker pins a canonical iconSlot-wide box to
  // that stable left edge, so the popout's computed center is constant
  // regardless of running state.
  Item {
    id: panelAnchor
    anchors.left: button.left
    anchors.verticalCenter: button.verticalCenter
    width: Style.bar.iconSlot
    height: button.height
    visible: false
  }

  KeyboardPanel {
    id: panel
    anchorItem: panelAnchor
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // 380, matching every other standard popout (audio/monitor/bluetooth/
    // power/network/agents all use the same Style.space(380); clock/weather
    // are the only first-party outliers, each for its own wider content).
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Without this, PanelKeyCatcher's own Keys.onPressed -- Keys.priority:
      // BeforeItem, so it sees every key before any focused descendant --
      // unconditionally accept()s Down/Up/Left/Right/j/k/h/l/x/X/Return/
      // Space/Tab/Escape and returns, so none of them ever reach a focused
      // TextField at all: arrow keys silently do nothing (moveRequested
      // isn't wired to anything either), and typing a "j"/"k"/"h"/"l"/"x"
      // character doesn't insert it. This is exactly the case
      // PanelKeyCatcher's own doc comment calls out ("a panel with an
      // inline editor... must set blocked: editor.activeFocus so the
      // editor receives keys normally") -- blocked for the whole time an
      // inline editor (the quick-add row or the edit form) is open, not
      // just per-field, since a focused Save/Start button needs
      // Return/Space to reach its own Keys.onReturnPressed too, not just
      // the text fields.
      blocked: root.quickAdding || root.editingTimer || root.discardConfirmOpen
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      // Enter/Space on a selected row toggles that row; with nothing
      // selected they act on the hero instead (stop, or resume the last
      // task), so "open popout, Space" is a one-key stop/resume.
      onActivateRequested: {
        if (root.cursorActive && root.selectedIndex < root.visibleTasks.length)
          root.toggleTask(root.visibleTasks[root.selectedIndex])
        else
          root.heroAction()
      }
      // Delete (or x, PanelKeyCatcher's own delete key) discards whatever
      // the pointer/cursor is on -- which only means anything for the
      // running timer; see deleteAtCursor(). PanelKeyCatcher has no
      // Delete binding, so that key arrives here as its "\u007f" text.
      onDeleteRequested: root.deleteAtCursor()
      onTextKey: function(t) {
        if (t === "\u007f") { root.deleteAtCursor(); return }
        if (t === "n" || t === "N" || t === "+") root.openQuickAdd()
        else if (t === "e" || t === "E") root.openEditTimer()
        else if (t === "s" || t === "S") { if (root.running) root.stopTimer() }
        else if (t === "o" || t === "O") { root.openTui(); root.close() }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · task/client (labels) · live clock ----------
        // Same shape as shell/plugins/panels/power/Panel.qml's own
        // heroIcon/heroLabels/heroPercent row -- an icon on the left, a
        // two-line label stack in the middle, and the single dominant
        // number on the right in Style.font.displayLarge.
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroTime.implicitHeight)

          // HoverHandler, not a MouseArea: observes without stealing the
          // clicks heroIcon/heroLabelsMouse handle themselves.
          HoverHandler {
            onHoveredChanged: root.heroHovered = hovered
          }

          // A large clickable stop button while running (not just an
          // icon) -- same md-stop glyph and "stop, not pause" reasoning
          // as the bar icon and list rows, just sized to match the hero's
          // own visual weight instead of a small bar-icon slot. Idle, it
          // becomes a play button that resumes the last task (heroMetaText
          // names it); only with no history at all is there nothing to do.
          PanelActionButton {
            id: heroIcon
            iconText: root.running ? "󰓛" : (root.resumeTask ? "󰐊" : "󱎫")
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.display
            size: Style.space(48)
            foreground: root.bar.foreground
            hoverColor: root.running ? root.bar.urgent : root.bar.foreground
            enabled: root.running || root.resumeTask !== null
            tooltipText: root.running ? "Stop timer (s)" : (root.resumeTask ? "Resume last task (space)" : "")
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.heroAction()
          }

          // Clickable to edit the running entry's client/project/notes --
          // not a separate button, deliberately. An earlier version added
          // a dedicated pencil-icon row below the hero, `visible:
          // root.running`, which shifted RECENT TIMERS and everything
          // after it down on *every* start (and back up on every stop),
          // not just when you actually opened the edit form. This hero
          // row, and heroLabels within it, exist unconditionally in both
          // states -- only the glyph/text they show changes -- so hanging
          // the click target and its hover highlight off heroLabels itself
          // adds an interaction without adding anything that appears or
          // disappears on its own.
          Item {
            id: heroLabelsArea
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroTime.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: heroLabels.implicitHeight

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              visible: root.running
              color: heroLabelsMouse.containsMouse
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              Behavior on color { ColorAnimation { duration: 120 } }
            }

            Column {
              id: heroLabels
              anchors.fill: parent
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.heroTaskText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                visible: root.heroMetaText !== ""
                text: root.heroMetaText.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }

            MouseArea {
              id: heroLabelsMouse
              anchors.fill: parent
              enabled: root.running
              hoverEnabled: true
              cursorShape: root.running ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.editingTimer ? root.cancelEditTimer() : root.openEditTimer()

              PanelToolTip {
                visible: root.running && !root.editingTimer && heroLabelsMouse.containsMouse
                text: "Click to edit · Delete to discard"
                fontFamily: root.bar.fontFamily
              }
            }
          }

          Text {
            id: heroTime
            textFormat: Text.PlainText
            text: root.heroTimeText
            color: root.running ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Today / this week ----------
        // Always present once summary is available (not gated on running),
        // so starting/stopping never shifts the layout below it.
        Row {
          visible: root.summaryAvailable
          width: parent.width
          spacing: Style.space(18)

          Repeater {
            model: [
              { label: "TODAY", seconds: root.todaySeconds },
              { label: "THIS WEEK", seconds: root.weekSeconds }
            ]
            Row {
              required property var modelData
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: modelData.label
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                anchors.baseline: totalValue.baseline
              }

              Text {
                id: totalValue
                textFormat: Text.PlainText
                text: Model.formatSeconds(modelData.seconds)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }
          }
        }

        // Last failed action's own message from notch (see actionProc).
        Text {
          visible: root.lastError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.lastError
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }

        // ---------- Edit form, for the running entry ----------
        // Triggered by clicking heroLabels itself (see its own comment) --
        // no separate toggle row here to keep out of the layout. Only
        // reachable while running: quick-add always starts on
        // Uncategorized/General with no task-time to lose, so there's
        // nothing to "edit" once idle -- reassigning a *finished* entry's
        // client/project isn't wired up here (notch edit --id would need
        // an entry picker of its own; out of scope for this round).
        //
        // Same card framing as the old up-front Add Timer form this
        // replaced (BorderSurface, subtle low-alpha wash -- see its own
        // comment for why not a hover-fill token), just applied to editing
        // instead of creating. Field order still task/client/project/notes
        // for consistency with the TUI's own layout, even though task is
        // usually already right coming out of quick-add.
        BorderSurface {
          width: parent.width
          visible: root.editingTimer
          radius: Style.cornerRadius
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.06)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
          implicitHeight: editForm.implicitHeight + Style.space(20)

          Column {
            id: editForm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            // Escape cancels the form instead of closing the whole popout
            // (PanelKeyCatcher's own Escape-closes-panel handling is
            // blocked for as long as this is open -- see keyCatcher.blocked
            // above). Standard QtQuick key bubbling: an unaccepted key
            // event from whichever field has focus propagates up through
            // its ancestors, so this doesn't need focus itself.
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelEditTimer()
                event.accepted = true
              }
            }

            TextField {
              id: editTaskField
              width: parent.width
              placeholderText: "Task"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onTextChanged: root.editTaskText = text
              onAccepted: editClientField.focusField()
            }

            NameField {
              id: editClientField
              width: parent.width
              placeholderText: "Client name (or leave blank)"
              options: root.allClients
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onTextEdited: function(t) { root.editClientText = t }
              onOptionSelected: function(opt) { root.editClientText = opt.name }
              onAdvanceRequested: editProjectField.focusField()
            }

            NameField {
              id: editProjectField
              width: parent.width
              placeholderText: "Project name (or leave blank)"
              options: root.editProjectOptions
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onTextEdited: function(t) { root.editProjectText = t }
              onOptionSelected: function(opt) {
                root.editProjectText = opt.name
                // Picking an existing project pins down its client too --
                // pushed into the client field directly (not just
                // root.editClientText) so what's on screen and what
                // actually submits can't diverge -- see openEditTimer()'s
                // comment for why a plain declarative binding on these
                // fields can't be trusted to do that on its own.
                if (opt.clientName) {
                  root.editClientText = opt.clientName
                  editClientField.text = opt.clientName
                }
              }
              onAdvanceRequested: editNotesField.forceActiveFocus()
            }

            TextField {
              id: editNotesField
              width: parent.width
              placeholderText: "Notes (optional)"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              onTextChanged: root.editNotesText = text
              onAccepted: root.submitEditTimer()
            }

            Button {
              width: parent.width
              leftAlign: true
              text: "Save"
              focusable: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.submitEditTimer()
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ---------- Recent timers: header (+ quick-add trigger), the
        // inline quick-add row, then the list ----------
        // No `visible: displayedTasks.length > 0` gate on this whole
        // section any more -- the header (and the "+" it now carries) has
        // to stay reachable even with zero recent timers, e.g. right after
        // a fresh install, or there'd be no way to add the very first one.
        // The Repeater below still naturally collapses to nothing on an
        // empty model without an explicit visible binding.
        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            height: Math.max(sectionHeader.implicitHeight, quickAddToggle.height)

            PanelSectionHeader {
              id: sectionHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "RECENT TIMERS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            // Klokki-style quick add: one editable row, not a form --
            // see quickAdding's own comment. Assigning a real
            // client/project happens after the fact via the edit form
            // near the hero, not up front here.
            PanelActionButton {
              id: quickAddToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.quickAdding ? "󰅖" : "󰐕"
              fontFamily: root.bar.fontFamily
              foreground: root.bar.foreground
              tooltipText: root.quickAdding ? "Cancel" : "Add timer (n)"
              bordered: true
              onClicked: root.quickAdding ? root.cancelQuickAdd() : root.openQuickAdd()
            }
          }

          // Styled like a real timer row below (icon + label slot at the
          // same positions rowIcon/labels use) so it reads as "a new row
          // that already exists, waiting for a name" rather than a
          // separate form bolted on -- the whole point of quick add.
          Item {
            width: parent.width
            visible: root.quickAdding
            height: quickAddField.implicitHeight + Style.space(16)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.06)
            }

            Item {
              width: Style.bar.iconCanvas
              height: Style.bar.iconCanvas
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter

              OpticalGlyph {
                anchors.fill: parent
                text: "󰐊"
                fontFamily: root.bar.fontFamily
                fontSize: Style.bar.iconFont
                color: root.bar.foreground
              }
            }

            TextField {
              id: quickAddField
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10) + Style.bar.iconCanvas + Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "New task, or type to find a recent one…"
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              // Typing narrows the list below (visibleTasks); a changed
              // query drops any arrow-picked row so Enter can't restart
              // something that's no longer what the text describes.
              onTextChanged: {
                root.quickAddQuery = text
                root.cursorActive = false
                root.selectedIndex = 0
              }
              onAccepted: root.submitQuickAdd()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.moveCursor(1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  if (root.cursorActive && root.selectedIndex === 0) root.cursorActive = false
                  else root.moveCursor(-1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (root.cursorActive) root.cursorActive = false
                  else root.cancelQuickAdd()
                  event.accepted = true
                }
              }
            }
          }

          // Not Button here: Button is single-line, and a combined label
          // at body size ran under the trailing time instead of eliding.
          // This anchors the label block between the icon and the time
          // (same technique as the hero row above: heroLabels anchored
          // icon.right..heroTime.left) so both label lines are actually
          // bounded and elide instead of overflowing -- task (the specific
          // thing being timed) bold and larger on top, project › client
          // dim and smaller below (client drops off first via elide if it
          // doesn't fit), time always visible on the right. Hover/active
          // fills reuse Style's own token functions (the same ones
          // Button.qml uses internally) so the look still matches the rest
          // of the kit without Button's single-line layout.
          Repeater {
            model: root.visibleTasks
            Item {
              id: row
              required property var modelData
              required property int index
              readonly property bool isActive: root.isTaskActive(modelData)
              readonly property bool rowSelected: root.cursorActive && root.selectedIndex === index
              readonly property int displaySeconds: (modelData.totalSeconds || 0) + (isActive ? root.elapsedSeconds : 0)
              readonly property string primaryLabel: modelData.task !== "" ? modelData.task : modelData.projectName
              // Client › Project, matching notch's own tooltip breadcrumb
              // convention (internal/status.FormatJSON: "%s › %s\n%s" =
              // client, project, task) -- same order the hero above uses,
              // rather than a third, invented order for this row.
              readonly property string secondaryLabel: modelData.task !== ""
                ? ((modelData.clientName ? modelData.clientName + " › " : "") + modelData.projectName)
                : modelData.clientName

              width: parent.width
              height: labels.implicitHeight + Style.space(16)

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleTask(row.modelData)
                // Hover moves the one shared cursor (CursorSurface's
                // contract: a single highlight across mouse and keyboard).
                // Not while quick-adding, though -- there the cursor is
                // what Enter restarts, and a mouse that happens to rest
                // over the list mustn't quietly change that.
                onEntered: if (!root.quickAdding) {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
                onExited: if (!root.quickAdding && root.selectedIndex === row.index) root.cursorActive = false
              }

              CursorSurface {
                anchors.fill: parent
                hasCursor: row.rowSelected
                current: row.isActive
                foreground: root.bar.foreground
              }

              // Fixed-size box, not a plain Text sized to its own glyph:
              // "▶"/"⚡" (still-different-width, same issue the bar icon
              // already hit) shifted `labels` sideways every time a row's
              // active state flipped, since labels anchors to rowIcon.right.
              // Nerd Font md-play/md-stop (matching the bar icon's own
              // md-timer/md-stop) rendered via OpticalGlyph inside a fixed
              // canvas, same as the bar icon, so this can't recur regardless
              // of which two glyphs are swapped in.
              Item {
                id: rowIcon
                width: Style.bar.iconCanvas
                height: Style.bar.iconCanvas
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter

                OpticalGlyph {
                  anchors.fill: parent
                  text: row.isActive ? "󰓛" : "󰐊"
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.bar.iconFont
                  color: root.bar.foreground
                }
              }

              Text {
                id: rowTime
                textFormat: Text.PlainText
                text: Model.formatSeconds(row.displaySeconds)
                color: row.isActive ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: labels
                anchors.left: rowIcon.right
                anchors.leftMargin: Style.space(10)
                anchors.right: rowTime.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  textFormat: Text.PlainText
                  text: row.primaryLabel
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  visible: row.secondaryLabel !== ""
                  text: row.secondaryLabel
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }
              }
            }
          }
        }

        Button {
          width: parent.width
          leftAlign: true
          text: "Open notch"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          onClicked: root.openTui()
        }
      }

      // Holds focus while the confirm is open (keyCatcher is blocked then)
      // and hands keys to ConfirmDialog's own handler: Left/Right/Tab
      // switch buttons, Enter picks, Escape cancels.
      Item {
        id: discardKeys
        Keys.onPressed: function(event) {
          if (discardConfirm.handleKey(event)) event.accepted = true
        }
      }

      ConfirmDialog {
        id: discardConfirm
        anchors.fill: parent
        z: 10
        opened: root.discardConfirmOpen
        message: "Discard “" + (root.statusTask !== "" ? root.statusTask : root.statusProjectName) + "”? "
          + root.heroTimeText + " of tracked time will be deleted."
        confirmText: "Discard"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        onCanceled: root.closeDiscardConfirm()
        onConfirmed: root.discardTimer()
      }
    }
  }

  // Inline, not a separate NameField.qml: Quickshell's plugin loader
  // (WidgetRegistry.qml's Qt.createComponent(dir + "/" + entry)) resolves
  // only the single manifest-declared entry point against its own "qs:"
  // virtual filesystem -- neither an implicit same-directory type lookup
  // nor an explicit `import "."` found a sibling .qml file there the way
  // a normal on-disk QML module would. shell/plugins/panels/power/Panel.qml
  // hits the identical need (small reusable sub-pieces, one file) with the
  // same fix: `component X: Y {}` declared inline (see its own
  // InfoPair/InfoLabel/InfoValue at the bottom of that file).
  //
  // Lightweight typeahead text field: type to filter existing options,
  // click a match to select it, or just leave your own text as-is to
  // create something new -- this only handles input + suggestion display,
  // the caller decides what "new" means (here, notch's own
  // --client-name/--project-name flags resolve-or-create). Modeled after
  // notch's TUI new-timer form (client/project fields with live-filtered
  // matches and a synthetic "+ Create X" hint), simplified for the popout:
  // an inline suggestion list under the field rather than a floating popup
  // with keyboard list-navigation -- qs.Ui's own SearchableDropdown is
  // pick-an-existing-option only (no way to submit free text), which is
  // exactly the gap this fills.
  component NameField: Item {
    id: nameFieldRoot

    property string text: ""
    property var options: []   // [{id, name, ...}, ...] -- name is matched on
    property string placeholderText: ""
    property color foreground: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family

    signal textEdited(string text)
    signal optionSelected(var option)
    // Enter with no suggestion highlighted -- the caller decides what
    // "next" means (this component has no idea what field follows it).
    signal advanceRequested()

    // Not an override of Item's own forceActiveFocus() (redeclaring an
    // inherited method's name is asking for trouble this can't be tested
    // for ahead of time) -- a distinctly-named function that redirects
    // focus to the actual input, since a plain Item can't itself hold
    // text-editing focus.
    function focusField() { nameFieldInput.forceActiveFocus() }

    // -1 = nothing highlighted (typing, mouse not hovering a row).
    property int currentIndex: -1

    readonly property string _query: text.trim().toLowerCase()
    readonly property bool _hasExactMatch: options.some(function(o) { return o.name.toLowerCase() === nameFieldRoot._query })
    readonly property var _matches: {
      if (nameFieldRoot._query === "") return []
      var out = []
      for (var i = 0; i < options.length; i++) {
        if (options[i].name.toLowerCase().indexOf(nameFieldRoot._query) !== -1) {
          out.push(options[i])
          if (out.length >= 5) break
        }
      }
      return out
    }
    readonly property bool _showCreateHint: nameFieldRoot._query !== "" && !nameFieldRoot._hasExactMatch
    readonly property bool _showSuggestions: nameFieldRoot._matches.length > 0 || nameFieldRoot._showCreateHint

    // Resets whenever the search text changes, which is the only thing
    // that meaningfully invalidates a stale highlighted index (_matches
    // is entirely derived from text).
    onTextChanged: currentIndex = -1

    implicitWidth: Style.space(200)
    implicitHeight: nameFieldColumn.implicitHeight

    Column {
      id: nameFieldColumn
      width: parent.width
      spacing: Style.space(4)

      TextField {
        id: nameFieldInput
        width: parent.width
        placeholderText: nameFieldRoot.placeholderText
        text: nameFieldRoot.text
        foreground: nameFieldRoot.foreground
        accent: nameFieldRoot.accent
        font.family: nameFieldRoot.fontFamily
        onTextChanged: {
          nameFieldRoot.text = text
          nameFieldRoot.textEdited(text)
        }

        // Arrow-key/Enter navigation over _matches -- mirrors
        // SearchableDropdown's own search-field-drives-a-result-list
        // shape (qs.Ui), just inline instead of in a floating popup.
        // Falls through (event left unaccepted) for anything not
        // explicitly handled here, e.g. Left/Right/Backspace edit the
        // text normally, and Tab moves to the next field via the
        // standard focus chain once PanelKeyCatcher is blocked.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down) {
            if (nameFieldRoot._matches.length === 0) return
            nameFieldRoot.currentIndex = Math.min(nameFieldRoot.currentIndex + 1, nameFieldRoot._matches.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            if (nameFieldRoot.currentIndex < 0) return
            nameFieldRoot.currentIndex -= 1
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (nameFieldRoot.currentIndex >= 0 && nameFieldRoot.currentIndex < nameFieldRoot._matches.length) {
              var opt = nameFieldRoot._matches[nameFieldRoot.currentIndex]
              nameFieldRoot.text = opt.name
              nameFieldRoot.optionSelected(opt)
              nameFieldRoot.currentIndex = -1
            } else {
              nameFieldRoot.advanceRequested()
            }
            event.accepted = true
          } else if (event.key === Qt.Key_Escape && nameFieldRoot.currentIndex >= 0) {
            nameFieldRoot.currentIndex = -1
            event.accepted = true
          }
        }
      }

      Column {
        width: parent.width
        visible: nameFieldRoot._showSuggestions
        spacing: Style.space(2)

        Repeater {
          model: nameFieldRoot._matches
          Rectangle {
            id: matchRow
            required property var modelData
            required property int index
            width: parent.width
            height: matchLabel.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: (matchMouse.containsMouse || index === nameFieldRoot.currentIndex)
              ? Style.hoverFillFor(nameFieldRoot.foreground, nameFieldRoot.accent) : "transparent"

            Behavior on color { ColorAnimation { duration: 120 } }

            Text {
              id: matchLabel
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              text: matchRow.modelData.name
              color: nameFieldRoot.foreground
              font.family: nameFieldRoot.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              id: matchMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: nameFieldRoot.currentIndex = matchRow.index
              onClicked: {
                nameFieldRoot.text = matchRow.modelData.name
                nameFieldRoot.optionSelected(matchRow.modelData)
              }
            }
          }
        }

        // Purely a hint, not a distinct action -- leaving the typed text
        // as it is already means "create new" once the form submits
        // (notch start --client-name/--project-name resolve-or-create),
        // so there's nothing this row needs to do beyond confirming
        // that's what'll happen.
        Text {
          visible: nameFieldRoot._showCreateHint
          textFormat: Text.PlainText
          leftPadding: Style.space(8)
          text: "+ Create “" + nameFieldRoot.text.trim() + "”"
          color: nameFieldRoot.accent
          font.family: nameFieldRoot.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.italic: true
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }
  }
}
