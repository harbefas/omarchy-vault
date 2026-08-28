import QtQuick
import qs.Commons
import qs.Ui

// Next-key overlay for shortcut mode. This mirrors the Spotify plugin's
// interaction pattern, but keeps the sequence parsing local to this plugin.
Item {
  id: root

  property var sequences: []
  property bool ctrlHeld: false
  property bool shiftHeld: false
  property bool altHeld: false
  property bool active: false
  property string navHint: ""
  property bool showWash: true
  property color foreground: Color.foreground
  property color hintColor: Color.accent

  readonly property color washColor: Util.alpha(hintColor, Style.hoverFillAlpha)
  readonly property color washBorder: Util.alpha(hintColor, Style.hoverBorderAlpha)
  readonly property color keycapFill: Util.alpha(hintColor, Style.selectedFillAlpha)
  readonly property color keycapBorder: Util.alpha(hintColor, Style.normalBorderAlpha)
  readonly property string label: overlayLabel()
  readonly property bool shown: label !== "" && (!parent || parent.enabled !== false)

  anchors.fill: parent
  visible: opacity > 0.01
  opacity: shown ? 1 : 0
  z: 24
  enabled: false
  clip: false

  Behavior on opacity { NumberAnimation { duration: 90 } }

  function sequenceList(value) {
    if (value === undefined || value === null || value === "") return []
    return Array.isArray(value) ? value : [value]
  }

  function parseSequence(sequence) {
    var raw = String(sequence || "").replace(/^\s+|\s+$/g, "")
    var result = { ctrl: false, shift: false, alt: false, key: "" }
    if (!raw) return result
    var parts = raw.split("+")
    for (var i = 0; i < parts.length; i++) {
      var part = String(parts[i] || "").replace(/^\s+|\s+$/g, "")
      if (!part) continue
      var lower = part.toLowerCase()
      if (lower === "ctrl" || lower === "control") result.ctrl = true
      else if (lower === "shift") result.shift = true
      else if (lower === "alt") result.alt = true
      else if (lower === "meta" || lower === "super") continue
      else result.key = part
    }
    return result
  }

  function modifiersMatch(sequence) {
    var parsed = parseSequence(sequence)
    return parsed.ctrl === ctrlHeld && parsed.shift === shiftHeld
      && parsed.alt === altHeld
  }

  function keycapFor(sequence) {
    var key = String(parseSequence(sequence).key || "")
    var lower = key.toLowerCase()
    if (lower === "left") return "←"
    if (lower === "right") return "→"
    if (lower === "up") return "↑"
    if (lower === "down") return "↓"
    if (lower === "space") return "Space"
    if (lower === "esc" || lower === "escape") return "Esc"
    if (lower === "enter" || lower === "return") return "Enter"
    if (lower === "tab") return "Tab"
    return key
  }

  function chordLabel() {
    if (active === false) return ""
    var list = sequenceList(sequences)
    var labels = []
    var seen = ({})
    for (var i = 0; i < list.length; i++) {
      if (!modifiersMatch(list[i])) continue
      var label = keycapFor(list[i])
      if (!label || seen[label]) continue
      seen[label] = true
      labels.push(label)
    }
    return labels.join(" ")
  }

  function overlayLabel() {
    if (active === false) return ""
    var nav = String(navHint || "")
    var chord = chordLabel()
    if (nav && chord && nav !== chord) return nav + " " + chord
    if (nav) return nav
    return chord
  }

  BorderSurface {
    anchors.fill: parent
    visible: root.showWash
    radius: Style.cornerRadius
    color: root.washColor
    borderSpec: Border.flat(root.washBorder,
      Math.max(1, Style.normalBorderWidth))
  }

  BorderSurface {
    id: keycap
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Math.max(1, Style.space(2))
    implicitWidth: keycapText.implicitWidth + Style.space(8)
    implicitHeight: keycapText.implicitHeight + Style.space(3)
    radius: Math.max(2, Math.round(Style.cornerRadius * 0.7))
    color: root.keycapFill
    borderSpec: Border.flat(root.keycapBorder,
      Math.max(1, Style.normalBorderWidth))

    Text {
      id: keycapText
      anchors.centerIn: parent
      text: root.label
      color: root.hintColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
