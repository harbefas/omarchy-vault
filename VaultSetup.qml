import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Column {
  id: root

  property color foreground: Color.foreground
  property color secondary: Util.alpha(foreground, 0.62)
  signal submitted(string path)

  spacing: Style.space(10)

  Text {
    width: parent.width
    text: "Choose your Markdown vault"
    textFormat: Text.PlainText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    wrapMode: Text.WordWrap
  }

  Text {
    width: parent.width
    text: "Enter the absolute path to the folder containing your .md files."
    textFormat: Text.PlainText
    color: root.secondary
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  TextField {
    id: pathField
    width: parent.width
    placeholderText: "/home/user/notes"
    foreground: root.foreground
    onAccepted: root.submitPath()
  }

  Button {
    text: "Use this folder"
    foreground: root.foreground
    enabled: pathField.text.trim() !== ""
    onClicked: root.submitPath()
  }

  function submitPath() {
    var value = pathField.text.trim()
    if (value !== "") root.submitted(value)
  }

  onVisibleChanged: if (visible)
    Qt.callLater(function() { pathField.forceActiveFocus() })
}
