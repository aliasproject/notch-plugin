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
  property real nowMs: Date.now()

  readonly property bool running: statusClass === "running"
  readonly property real startTimeMs: statusStartTime !== "" ? Date.parse(statusStartTime) : 0
  readonly property int elapsedSeconds: running && startTimeMs > 0
    ? Math.max(0, Math.floor((nowMs - startTimeMs) / 1000))
    : 0

  readonly property string heroTimeText: Model.formatSeconds(elapsedSeconds)
  readonly property string heroTaskText: running ? statusTask : "No timer running"
  readonly property string heroMetaText: running ? (statusClientName + " › " + statusProjectName) : ""

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function refreshTasks() {
    if (!tasksProc.running) tasksProc.running = true
  }

  function startTask(projectId, task) {
    if (actionProc.running) return
    actionProc.command = ["notch", "start", "--project", String(projectId), "--task", task || ""]
    actionProc.running = true
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

  onOpenedChanged: if (opened) refreshTasks()

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
      onStreamFinished: root.recentTasks = Model.parseTasks(text)
    }
  }

  // Fire-and-forget: start/stop don't print anything worth reading, so
  // just re-poll status + totals once the process exits (whether it
  // succeeded or not -- a failed start/stop should still show the real
  // current state, not a stale optimistic one).
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
  // to grow the slot instead of overflowing it. Idle and running are
  // genuinely different shapes, so the button switches modes between them,
  // same as shell/plugins/panels/clock/Panel.qml switches its own
  // WidgetButton between a fixed vertical icon column and a free-width
  // horizontal label -- except neither mode here uses WidgetButton's own
  // built-in label at all (labelVisible stays false always): both render
  // their own OpticalGlyph/Text children instead, so the running state can
  // give its icon its own MouseArea (see below) without fighting
  // WidgetButton's single whole-button click region.
  //   - idle: fixedWidth pinned to Style.bar.iconSlot (matching every
  //     sibling BarIconButton's slot exactly) and an OpticalGlyph -- the
  //     same optically-corrected glyph rendering BarIconButton itself uses
  //     internally -- so the idle icon is pixel-identical in size and
  //     centering to the other bar icons.
  //   - running: icon + live time only (no task name -- deliberately kept
  //     minimal; the task is one click away in the popout), auto-width
  //     sized from the row's own implicit width since nothing here comes
  //     from WidgetButton's label metrics anymore.
  // The glyph is the Nerd Font "md-timer" PUA codepoint (U+F13AB), not the
  // plain Unicode "⏱" stopwatch character -- that one renders noticeably
  // smaller than every sibling's purpose-built icon glyph even at the same
  // Style.bar.iconFont size, since it isn't part of the icon glyph set the
  // rest of the bar draws from.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: root.running ? (runningRow.implicitWidth + Style.space(17)) : Style.bar.iconSlot
    labelVisible: false
    hasVisualContent: true
    tooltipText: root.statusTooltip
    // Whole-button fallback: catches the cross-widget popout-switch path
    // (KeyboardPanel's dismissArea calls triggerPress() directly on the
    // registered click target, bypassing normal hit-testing entirely) and
    // any click on the running row that isn't over the icon's own
    // MouseArea below -- i.e. the time digits, or idle mode entirely.
    onPressed: root.toggle()

    Item {
      visible: !root.running
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      OpticalGlyph {
        anchors.fill: parent
        text: "󱎫"
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.foreground
      }
    }

    Row {
      id: runningRow
      visible: root.running
      anchors.centerIn: parent
      spacing: Style.space(6)

      // Icon zone: its own MouseArea, layered on top of (and consuming
      // clicks before) WidgetButton's own full-area mouseArea underneath --
      // standard QtQuick overlay hit-testing, no special wiring needed.
      // notch has no true pause/resume, only start/stop, so this stops the
      // running entry outright (same action the popout's active row does),
      // not a resumable pause.
      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        anchors.verticalCenter: parent.verticalCenter

        OpticalGlyph {
          anchors.fill: parent
          text: "󱎫"
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
          color: button.foreground
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.stopTimer()
        }
      }

      // Time zone: no MouseArea of its own -- falls through to
      // WidgetButton's onPressed above, which opens the popout.
      Text {
        textFormat: Text.PlainText
        text: root.heroTimeText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
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

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󱎫"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
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

        // ---------- Recent timers: flat list, running one highlighted ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.recentTasks.length > 0

          PanelSectionHeader {
            text: "RECENT TIMERS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
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
            model: root.recentTasks
            Item {
              id: row
              required property var modelData
              readonly property bool isActive: root.running
                && modelData.projectId === root.statusProjectId
                && modelData.task === root.statusTask
              readonly property int displaySeconds: (modelData.totalSeconds || 0) + (isActive ? root.elapsedSeconds : 0)
              readonly property string primaryLabel: modelData.task !== "" ? modelData.task : modelData.projectName
              readonly property string secondaryLabel: modelData.task !== ""
                ? (modelData.projectName + (modelData.clientName ? " › " + modelData.clientName : ""))
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

              Text {
                id: rowIcon
                textFormat: Text.PlainText
                text: row.isActive ? "⚡" : "▶"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.icon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
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
}
