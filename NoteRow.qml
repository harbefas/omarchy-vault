import QtQuick
import qs.Commons

// One note in a list. Shared by the bar popup and the full panel so both
// surfaces stay identical — same type scale, same single foreground colour at
// two opacities, no second hue anywhere.
Rectangle {
  id: root

  property string title: ""
  property string folder: ""
  property string age: ""
  property bool selected: false
  property color foreground: Color.foreground
  property bool compact: false

  readonly property color secondary: Util.alpha(foreground, 0.55)

  signal pressed()
  signal activated()

  height: compact ? Style.space(34) : Style.space(46)
  color: selected
    ? Util.alpha(foreground, 0.10)
    : (mouse.containsMouse ? Util.alpha(foreground, 0.06) : "transparent")

  Column {
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: ageLabel.left
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(1)

    Text {
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: root.compact ? Style.font.bodySmall : Style.font.body
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.folder
      textFormat: Text.PlainText
      visible: root.folder !== "" && !root.compact
      color: root.secondary
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideLeft
    }
  }

  Text {
    id: ageLabel
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    text: root.age
    textFormat: Text.PlainText
    color: root.secondary
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    hoverEnabled: true
    onPressed: root.pressed()
    onClicked: root.activated()
  }
}
