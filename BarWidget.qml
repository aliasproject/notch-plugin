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
  property string statusStartTime: ""
  property int statusProjectId: 0
  property string statusProjectName: ""
  property string statusClientName: ""
  property var recentTasks: []
  property var allProjects: []
  property var allClients: []
  property bool addingTimer: false
  // Order matches notch's own TUI new-timer form: task, then client, then
  // project, then notes (internal/ui/views/timers.go's fieldTask/
  // fieldClient/fieldProject/fieldNotes). Client/project are free text,
  // not an ID selection -- resolved-or-created server-side by "notch
  // start --client-name/--project-name" (db.ResolveOrCreateProject),
  // exactly like the TUI's own form always does regardless of whether you
  // picked a suggestion or typed a new name.
  property string newTimerTask: ""
  property string newTimerClientText: ""
  property string newTimerProjectText: ""
  property string newTimerNotes: ""
  property real nowMs: Date.now()
  // true right before a refresh that should re-sort to the server's true
  // recency order (a fresh open); false for a refresh triggered by a
  // start/stop action while already open, which should keep the on-screen
  // row order fixed instead -- see Model.reorderTasksInPlace.
  property bool tasksNeedFreshSort: true

  readonly property bool running: statusClass === "running"
  readonly property real startTimeMs: statusStartTime !== "" ? Date.parse(statusStartTime) : 0
  readonly property int elapsedSeconds: running && startTimeMs > 0
    ? Math.max(0, Math.floor((nowMs - startTimeMs) / 1000))
    : 0

  readonly property string heroTimeText: Model.formatSeconds(elapsedSeconds)
  readonly property string heroTaskText: running ? statusTask : "No timer running"
  readonly property string heroMetaText: running ? (statusClientName + " › " + statusProjectName) : ""

  // What the list actually renders. "notch tasks -json" only reports
  // *finished* entries (see notch's ListRecentTasks), so a task started
  // just now -- even one that's been done before -- doesn't appear in
  // recentTasks at all until it's stopped. This pins whichever task is
  // currently running to the front for display, pulling its existing row
  // (with its real prior total) up if it has one, or synthesizing one at
  // 0 total if it doesn't -- so starting a timer shows it at the top
  // immediately, without waiting for a stop. recentTasks itself (and its
  // stable ordering from Model.reorderTasksInPlace) is untouched; this is
  // purely a display-time view over it.
  readonly property var displayedTasks: {
    if (!running) return recentTasks
    var activeKey = statusProjectId + " " + statusTask
    var activeEntry = null
    var rest = []
    for (var i = 0; i < recentTasks.length; i++) {
      var t = recentTasks[i]
      if (!activeEntry && (t.projectId + " " + t.task) === activeKey) activeEntry = t
      else rest.push(t)
    }
    if (!activeEntry) {
      activeEntry = {
        projectId: statusProjectId, projectName: statusProjectName,
        clientName: statusClientName, task: statusTask, totalSeconds: 0
      }
    }
    return [activeEntry].concat(rest)
  }

  // Project field's suggestion pool, narrowed to whichever client is
  // currently typed IF it exactly (case-insensitively) matches an
  // existing client -- "task, then client, then project" only works as a
  // funnel if picking a real client actually shrinks the project list.
  // A new (not-yet-existing) or blank client can't scope anything yet, so
  // every project is offered instead of none.
  readonly property var newTimerMatchedClient: {
    var q = newTimerClientText.trim().toLowerCase()
    if (q === "") return null
    for (var i = 0; i < allClients.length; i++) {
      if (allClients[i].name.toLowerCase() === q) return allClients[i]
    }
    return null
  }
  readonly property var newTimerProjectOptions: newTimerMatchedClient
    ? allProjects.filter(function(p) { return p.clientId === newTimerMatchedClient.id })
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

  // Used by the recent-timers list, which already has a concrete project
  // ID for each row.
  function startTask(projectId, task, notes) {
    if (actionProc.running) return
    var cmd = ["notch", "start", "--project", String(projectId), "--task", task || ""]
    if (notes) cmd.push("--notes", notes)
    actionProc.command = cmd
    actionProc.running = true
  }

  // Used by the Add Timer form, which only has typed client/project names
  // (possibly brand new ones) -- notch resolves-or-creates them server-side.
  function startTaskByName(clientName, projectName, task, notes) {
    if (actionProc.running) return
    var cmd = ["notch", "start", "--task", task || ""]
    if (clientName) cmd.push("--client-name", clientName)
    if (projectName) cmd.push("--project-name", projectName)
    if (notes) cmd.push("--notes", notes)
    actionProc.command = cmd
    actionProc.running = true
  }

  // "Add a timer": the recent-tasks list only ever offers what's already
  // been tracked before, so this is the only way to start a genuinely new
  // task (or a brand new client/project) from the popout instead of
  // falling back to the full TUI. Field order matches notch's own TUI
  // new-timer form: task, then client, then project, then notes.
  function openAddTimer() {
    addingTimer = true
    newTimerTask = ""
    newTimerClientText = ""
    newTimerProjectText = ""
    newTimerNotes = ""
    // Fields' own `text` is set imperatively here and nowhere else
    // declaratively (see the field instantiations below for why: a plain
    // `text: root.newTimerXxx` binding gets silently severed the moment
    // the field's own onTextChanged assigns to it, which is every
    // keystroke -- after that, an external write to root.newTimerXxx,
    // like the project field's own "picking a project also fills in its
    // client" cross-write, would update state used at submit time without
    // the visible field ever showing it).
    addTimerTaskField.text = ""
    addTimerClientField.text = ""
    addTimerProjectField.text = ""
    addTimerNotesField.text = ""
    // Same Qt.callLater-after-becoming-visible idiom qs.Ui's own
    // SearchableDropdown uses to focus its search field on open -- the
    // field exists and is visible immediately (addingTimer just toggles
    // an ordinary Column's `visible`, nothing is being created/loaded),
    // but focus needs to land after this function returns and the
    // visibility change has actually taken effect.
    Qt.callLater(function() { addTimerTaskField.forceActiveFocus() })
  }

  function cancelAddTimer() {
    addingTimer = false
  }

  readonly property bool canSubmitAddTimer: newTimerTask.trim() !== ""
    && (newTimerClientText.trim() !== "" || newTimerProjectText.trim() !== "")

  function submitAddTimer() {
    if (!canSubmitAddTimer) return
    startTaskByName(newTimerClientText.trim(), newTimerProjectText.trim(), newTimerTask.trim(), newTimerNotes.trim())
    addingTimer = false
  }

  function stopTimer() {
    if (actionProc.running) return
    actionProc.command = ["notch", "stop"]
    actionProc.running = true
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
    refreshTasks()
    refreshProjects()
    refreshClients()
  } else {
    addingTimer = false
  }

  Process {
    id: statusProc
    command: ["notch", "status", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatus(text)
        root.statusText = parsed.text
        root.statusTooltip = parsed.tooltip
        root.statusClass = parsed.class
        root.statusTask = parsed.task
        root.statusStartTime = parsed.startTime
        root.statusProjectId = parsed.projectId
        root.statusProjectName = parsed.projectName
        root.statusClientName = parsed.clientName
        root.nowMs = Date.now()
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
  Process {
    id: actionProc
    onExited: {
      root.refreshStatus()
      root.refreshTasks()
    }
  }

  Process {
    id: launchProc
  }

  // Correctness poll: catches state changes made elsewhere (the TUI,
  // another client) that this widget wouldn't otherwise see. Ticking
  // between polls is handled locally below, so this doesn't need to be
  // fast.
  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
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
    Text {
      id: timeText
      visible: root.running
      textFormat: Text.PlainText
      text: root.heroTimeText
      color: button.foreground
      font.family: button.fontFamily
      font.pixelSize: Style.bar.iconFont
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
      // editor receives keys normally") -- blocked for the whole time the
      // Add Timer form is open, not just per-field, since a focused Start
      // button needs Return/Space to reach its own Keys.onReturnPressed
      // too, not just the text fields.
      blocked: root.addingTimer
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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

          // A large clickable stop button while running (not just an
          // icon) -- same md-stop glyph and "stop, not pause" reasoning
          // as the bar icon and list rows, just sized to match the hero's
          // own visual weight instead of a small bar-icon slot. Disabled
          // (no hover/click) when idle -- there's nothing to stop.
          PanelActionButton {
            id: heroIcon
            iconText: root.running ? "󰓛" : "󱎫"
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.display
            size: Style.space(48)
            foreground: root.bar.foreground
            hoverColor: root.running ? root.bar.urgent : root.bar.foreground
            enabled: root.running
            tooltipText: root.running ? "Stop timer" : ""
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.stopTimer()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroTime.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
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

          Text {
            id: heroTime
            textFormat: Text.PlainText
            text: root.heroTimeText
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        // ---------- Recent timers: header (+ Add Timer trigger), the
        // expandable Add Timer form, then the list ----------
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
            height: Math.max(sectionHeader.implicitHeight, addTimerToggle.height)

            PanelSectionHeader {
              id: sectionHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "RECENT TIMERS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            // The recent-timers list only ever offers what's already been
            // tracked before, so this is the only way to start a
            // genuinely new task -- or a brand new client/project -- from
            // the popout instead of falling back to the full TUI.
            PanelActionButton {
              id: addTimerToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.addingTimer ? "󰅖" : "󰐕"
              fontFamily: root.bar.fontFamily
              foreground: root.bar.foreground
              tooltipText: root.addingTimer ? "Cancel" : "Add timer"
              bordered: true
              onClicked: root.addingTimer ? root.cancelAddTimer() : root.openAddTimer()
            }
          }

          // Framed as a distinct card (BorderSurface, the same primitive
          // Button/Dropdown/PanelActionButton build on) so the form reads
          // as one contained unit next to the list rather than a handful
          // of fields blending into the rest of the popout. Field order
          // (task, client, project, notes) and the resolve-existing-or-
          // create behavior for client/project both match notch's own TUI
          // new-timer form exactly (see db.ResolveOrCreateProject);
          // NameField's inline suggestion list + "+ Create" hint is this
          // popout's own take on the TUI's live-filtered client/project
          // fields, not a literal copy of its layout.
          BorderSurface {
            width: parent.width
            visible: root.addingTimer
            radius: Style.cornerRadius
            // Subtle low-alpha foreground wash, not a hover-state fill --
            // same technique power/Panel.qml uses for its battery bar
            // track (Qt.rgba(...foreground, 0.12)), so this reads as a
            // static section background rather than looking permanently
            // "hovered."
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.06)
            borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
            implicitHeight: addTimerForm.implicitHeight + Style.space(20)

            Column {
              id: addTimerForm
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              // Escape cancels the form instead of closing the whole
              // popout (PanelKeyCatcher's own Escape-closes-panel handling
              // is blocked for as long as the form is open -- see
              // keyCatcher.blocked above). Standard QtQuick key bubbling:
              // an unaccepted key event from whichever field has focus
              // propagates up through its ancestors, so this doesn't need
              // focus itself.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelAddTimer()
                  event.accepted = true
                }
              }

              // Enter advances field-to-field (Task -> Client -> Project ->
              // Notes -> submit), matching the TUI's own new-timer form
              // flow. NameField's advanceRequested only fires when Enter
              // is pressed with no suggestion highlighted -- with one
              // highlighted, Enter selects it instead (see NameField's own
              // Keys.onPressed).
              // None of these four fields declares `text: root.newTimerXxx`
              // -- see openAddTimer()'s own comment for why a persistent
              // binding there is a trap (silently severed by the field's
              // own onTextChanged on the very first keystroke). Each
              // field's text is set imperatively (reset in openAddTimer(),
              // or here when a selection needs to push a value into a
              // *different* field) and read back via onTextChanged/
              // onTextEdited/onOptionSelected only.
              TextField {
                id: addTimerTaskField
                width: parent.width
                placeholderText: "What are you working on?"
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily
                onTextChanged: root.newTimerTask = text
                onAccepted: addTimerClientField.focusField()
              }

              NameField {
                id: addTimerClientField
                width: parent.width
                placeholderText: "Client name (or leave blank)"
                options: root.allClients
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onTextEdited: function(t) { root.newTimerClientText = t }
                onOptionSelected: function(opt) { root.newTimerClientText = opt.name }
                onAdvanceRequested: addTimerProjectField.focusField()
              }

              NameField {
                id: addTimerProjectField
                width: parent.width
                placeholderText: "Project name (or leave blank)"
                options: root.newTimerProjectOptions
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onTextEdited: function(t) { root.newTimerProjectText = t }
                onOptionSelected: function(opt) {
                  root.newTimerProjectText = opt.name
                  // Picking an existing project pins down its client too --
                  // matches the TUI's own project-select behavior (see
                  // timers.go: selecting a project match also fills the
                  // client field). Pushed into the client field directly
                  // (not just root.newTimerClientText) so what's on screen
                  // and what actually submits can't diverge -- that
                  // divergence, via the now-removed persistent binding
                  // above, was the real bug an earlier version of this
                  // form had.
                  if (opt.clientName) {
                    root.newTimerClientText = opt.clientName
                    addTimerClientField.text = opt.clientName
                  }
                }
                onAdvanceRequested: addTimerNotesField.forceActiveFocus()
              }

              TextField {
                id: addTimerNotesField
                width: parent.width
                placeholderText: "Notes (optional)"
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily
                onTextChanged: root.newTimerNotes = text
                onAccepted: root.submitAddTimer()
              }

              Button {
                width: parent.width
                leftAlign: true
                text: "Start"
                enabled: root.canSubmitAddTimer
                focusable: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.submitAddTimer()
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
            model: root.displayedTasks
            Item {
              id: row
              required property var modelData
              readonly property bool isActive: root.running
                && modelData.projectId === root.statusProjectId
                && modelData.task === root.statusTask
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
                onClicked: row.isActive ? root.stopTimer() : root.startTask(modelData.projectId, modelData.task)
              }

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: row.isActive
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent)
                  : (rowMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent")

                Behavior on color { ColorAnimation { duration: 120 } }
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
