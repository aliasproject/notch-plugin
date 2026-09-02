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
Panel {
  id: root
  moduleName: "io.github.aliasproject.notch"
  ipcTarget: "io.github.aliasproject.notch"

  property string statusText: ""
  property string statusTooltip: "No timer running"
  property string statusClass: "idle"
  property var projects: []
  readonly property bool running: statusClass === "running"

  // statusTooltip is "<client> › <project>\n<task>" while running (see
  // notch's internal/status.FormatJSON) -- split it for the popout hero
  // instead of re-deriving the same thing from a second CLI call.
  readonly property var tooltipLines: statusTooltip.split("\n")
  readonly property string heroTitle: running ? (tooltipLines[1] || "Running") : "No timer running"
  readonly property string heroMeta: running ? (tooltipLines[0] || "") : "Idle"

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
  // just re-poll status once the process exits (whether it succeeded or
  // not -- a failed start/stop should still show the real current state,
  // not a stale optimistic one).
  Process {
    id: actionProc
    onExited: root.refreshStatus()
  }

  Process {
    id: launchProc
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // root is a plain Item (Panel.qml's base) with no implicit size of its
  // own -- every first-party bar item (system-update, weather, power)
  // binds implicitWidth/Height to its inner button explicitly, or the bar's
  // layout gives it zero size and it silently never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // WidgetButton, not BarIconButton: BarIconButton is a fixed icon-slot
  // square (an OpticalGlyph painted into a small fixed canvas, no eliding)
  // meant for single glyphs, so a running timer's "⏱ Build feature ·
  // 1:23:45" painted straight past its bounds into the neighboring widgets.
  // WidgetButton has no fixed width by default -- it measures its label and
  // grows to fit, same as shell/plugins/panels/clock/Panel.qml's live
  // date/time text.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.running ? root.statusText : "⏱"
    tooltipText: root.statusTooltip
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
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

        PanelHero {
          width: parent.width
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "⏱"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          title: root.heroTitle
          meta: root.heroMeta
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.projects.length > 0

          PanelSectionHeader {
            text: "PROJECTS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.projects
            Button {
              required property var modelData
              width: parent.width
              leftAlign: true
              text: (modelData.clientName ? modelData.clientName + " › " : "") + modelData.name
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.startProject(modelData.id)
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: parent.width
            visible: root.running
            leftAlign: true
            text: "Stop timer"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.stopTimer()
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
}
