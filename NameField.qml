import QtQuick
import qs.Commons
import qs.Ui

// Lightweight typeahead text field: type to filter existing options,
// click a match to select it, or just leave your own text as-is to create
// something new -- this component only handles input + suggestion
// display, the caller decides what "new" means (here, notch's own
// --client-name/--project-name flags resolve-or-create). Modeled after
// notch's TUI new-timer form (client/project fields with live-filtered
// matches and a synthetic "+ Create X" hint), simplified for the popout:
// an inline suggestion list under the field rather than a floating popup
// with keyboard list-navigation -- qs.Ui's own SearchableDropdown is
// pick-an-existing-option only (no way to submit free text), which is
// exactly the gap this fills.
Item {
  id: root

  property string text: ""
  property var options: []   // [{id, name, ...}, ...] -- name is matched on
  property string placeholderText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal textEdited(string text)
  signal optionSelected(var option)

  readonly property string _query: text.trim().toLowerCase()
  readonly property bool _hasExactMatch: options.some(function(o) { return o.name.toLowerCase() === root._query })
  readonly property var _matches: {
    if (root._query === "") return []
    var out = []
    for (var i = 0; i < options.length; i++) {
      if (options[i].name.toLowerCase().indexOf(root._query) !== -1) {
        out.push(options[i])
        if (out.length >= 5) break
      }
    }
    return out
  }
  readonly property bool _showCreateHint: root._query !== "" && !root._hasExactMatch
  readonly property bool _showSuggestions: root._matches.length > 0 || root._showCreateHint

  implicitWidth: Style.space(200)
  implicitHeight: column.implicitHeight

  Column {
    id: column
    width: parent.width
    spacing: Style.space(4)

    TextField {
      id: field
      width: parent.width
      placeholderText: root.placeholderText
      text: root.text
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      onTextChanged: {
        root.text = text
        root.textEdited(text)
      }
    }

    Column {
      id: suggestions
      width: parent.width
      visible: root._showSuggestions
      spacing: Style.space(2)

      Repeater {
        model: root._matches
        Rectangle {
          id: matchRow
          required property var modelData
          width: parent.width
          height: matchLabel.implicitHeight + Style.space(10)
          radius: Style.cornerRadius
          color: matchMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

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
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          MouseArea {
            id: matchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.text = matchRow.modelData.name
              root.optionSelected(matchRow.modelData)
            }
          }
        }
      }

      // Purely a hint, not a distinct action -- leaving the typed text as
      // it is already means "create new" once the form submits (notch
      // start --client-name/--project-name resolve-or-create), so there's
      // nothing this row needs to do beyond confirming that's what'll
      // happen.
      Text {
        visible: root._showCreateHint
        textFormat: Text.PlainText
        leftPadding: Style.space(8)
        text: "+ Create “" + root.text.trim() + "”"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
        elide: Text.ElideRight
        width: parent.width
      }
    }
  }
}
