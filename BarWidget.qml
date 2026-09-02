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
// ("notch status/projects/start/stop -json") that opens the sqlite db,
// does one thing, and exits — see notch's README "Scripting" section.
// The popout's hero clock and each project row's running time tick
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
  property var projects: []
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

  function refreshProjects() {
    if (!projectsProc.running) projectsProc.running = true
  }

  function startProject(projectId) {
    if (actionProc.running) return
    actionProc.command = ["notch", "start", "--project", String(projectId)]
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

  onOpenedChanged: if (opened) refreshProjects()

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
    id: projectsProc
    command: ["notch", "projects", "-json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.projects = Model.parseProjects(text)
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
      root.refreshProjects()
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
  // square meant for single glyphs, so a running timer's "⏱ Build feature ·
  // 1:23:45" doesn't fit it. Idle and running are genuinely different
  // shapes, so the button switches modes between them, same as
  // shell/plugins/panels/clock/Panel.qml switches its own WidgetButton
  // between a fixed vertical icon column and a free-width horizontal label:
  //   - idle: fixedWidth pinned to Style.bar.iconSlot (matching every
  //     sibling BarIconButton's slot exactly) and an OpticalGlyph -- the
  //     same optically-corrected glyph rendering BarIconButton itself uses
  //     internally -- so the idle "⏱" is pixel-identical in size and
  //     centering to the other bar icons.
  //   - running: label text, auto-width (WidgetButton's default), so
  //     arbitrary-length task text grows the slot instead of overflowing it.
  //     Ticks every second locally (see elapsedSeconds) rather than only
  //     on notch's own poll cadence.
  // WidgetButton's own label/height already center on both axes against
  // the full bar height, matching every other widget.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fixedWidth: root.running ? -1 : Style.bar.iconSlot
    labelVisible: root.running
    hasVisualContent: root.running ? text !== "" : true
    text: root.running ? ("⏱ " + root.statusTask + " · " + root.heroTimeText) : ""
    tooltipText: root.statusTooltip
    onPressed: root.toggle()

    Item {
      visible: !root.running
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      OpticalGlyph {
        anchors.fill: parent
        text: "⏱"
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.foreground
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
            text: "⏱"
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

        // ---------- Timers: flat list, running one highlighted ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.projects.length > 0

          PanelSectionHeader {
            text: "TIMERS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.projects
            Item {
              id: row
              required property var modelData
              readonly property bool isActive: root.running && modelData.id === root.statusProjectId
              readonly property int displaySeconds: (modelData.totalSeconds || 0) + (isActive ? root.elapsedSeconds : 0)

              width: parent.width
              height: rowButton.implicitHeight

              Button {
                id: rowButton
                anchors.fill: parent
                leftAlign: true
                iconText: row.isActive ? "⚡" : "▶"
                text: (modelData.clientName ? modelData.clientName + " › " : "") + modelData.name
                active: row.isActive
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: row.isActive ? root.stopTimer() : root.startProject(modelData.id)
              }

              Text {
                textFormat: Text.PlainText
                text: Model.formatSeconds(row.displaySeconds)
                color: row.isActive ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.right: parent.right
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
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
