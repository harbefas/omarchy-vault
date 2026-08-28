import QtQuick
import qs.Commons
import qs.Ui

import "Vault.js" as Vault

BarWidget {
  id: root
  moduleName: "harbefas.vault"

  readonly property var vault: bar && bar.shell
    ? bar.shell.serviceFor("harbefas.vault") : null
  readonly property bool vaultConfigured: root.vault && root.vault.vaultConfigured
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color secondary: Util.alpha(foreground, 0.55)
  readonly property var popupNotes: vault ? vault.notes.slice(0, 12) : []
  property string selectedLabel: ""

  property bool popupOpen: false
  property int popupIndex: 0
  property bool shortcutHintsActive: true
  property int heldModifierFlags: 0
  property int popupOpens: 0
  readonly property int tipOpenLimit: 3
  readonly property bool showBindTip: root.vault
    && root.vault.bindingsReady
    && !root.vault.keybindConfigured
    && root.popupOpens <= root.tipOpenLimit

  readonly property bool opened: popupOpen
  readonly property bool hintCtrlHeld: (heldModifierFlags & Qt.ControlModifier) !== 0
  readonly property bool hintShiftHeld: (heldModifierFlags & Qt.ShiftModifier) !== 0
  readonly property bool hintAltHeld: (heldModifierFlags & Qt.AltModifier) !== 0

  component KeyHint: ShortcutHint {
    ctrlHeld: root.hintCtrlHeld
    shiftHeld: root.hintShiftHeld
    altHeld: root.hintAltHeld
    active: root.shortcutHintsActive
    foreground: root.foreground
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onVaultChanged: if (vault) vault.applySettings(root.settings)
  onPopupNotesChanged: {
    root.ensurePopupSelection()
    root.updateSelectedLabel()
  }
  onPopupIndexChanged: root.updateSelectedLabel()

  function openPopup() {
    if (vault) { vault.setQuery(""); vault.refresh() }
    searchField.text = ""
    shortcutHintsActive = true
    popupOpen = true
    popupOpens += 1
    ensurePopupSelection()
    Qt.callLater(function() { popupKeyCatcher.forceActiveFocus() })
  }

  function open() {
    openPopup()
  }

  function closePopup() {
    popupOpen = false
    heldModifierFlags = 0
  }

  function close() {
    closePopup()
  }

  function toggle() {
    popupOpen ? closePopup() : openPopup()
  }

  // The popup is the everyday surface; the full window is the escape hatch,
  // reached from here or from SUPER+SHIFT+V.
  function openFull(payload) {
    closePopup()
    if (!bar || !bar.shell) return
    var next = payload || ({})
    next.settings = root.settings
    next.shortcutLatch = root.shortcutHintsActive
    var encoded = JSON.stringify(next)
    if (typeof bar.shell.hide === "function"
        && typeof bar.shell.summon === "function") {
      bar.shell.hide("harbefas.vault")
      Qt.callLater(function() {
        if (root.bar && root.bar.shell)
          root.bar.shell.summon("harbefas.vault", encoded)
      })
    } else if (typeof bar.shell.summon === "function") {
      bar.shell.summon("harbefas.vault", encoded)
    }
  }

  function ensurePopupSelection() {
    if (!popupNotes.length) {
      popupIndex = -1
      return
    }
    if (popupIndex < 0) popupIndex = 0
    if (popupIndex >= popupNotes.length) popupIndex = popupNotes.length - 1
  }

  function selectPopupIndex(index) {
    var next = Number(index)
    if (!isFinite(next) || next < 0 || next >= popupNotes.length) return
    popupIndex = next
    noteList.forceActiveFocus()
  }

  function movePopupSelection(delta) {
    if (!popupNotes.length) return
    ensurePopupSelection()
    popupIndex = (popupIndex + (delta < 0 ? -1 : 1) + popupNotes.length)
      % popupNotes.length
    noteList.positionViewAtIndex(popupIndex, ListView.Contain)
    noteList.forceActiveFocus()
  }

  function selectedNote() {
    return popupIndex >= 0 && popupIndex < popupNotes.length
      ? popupNotes[popupIndex] : null
  }

  function updateSelectedLabel() {
    selectedLabel = noteLabel(selectedNote())
  }

  function shortcutSuggestionText() {
    var service = root.vault
    if (!service || typeof service.suggestedBind !== "string") return ""
    return "Suggested shortcut: Super+Alt+V\n" + service.suggestedBind
  }

  function saveVaultPath(path) {
    var value = String(path || "").trim()
    if (!value || !root.vault) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.vaultPath = value
    root.settings = entry
    root.vault.applySettings(entry)
    if (root.bar && root.bar.shell
        && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    root.vault.refresh()
    Qt.callLater(function() {
      if (root.popupOpen) popupKeyCatcher.forceActiveFocus()
    })
  }

  function noteLabel(note) {
    if (!note) return ""
    return note.folder ? note.folder + "/" + note.title : note.title
  }

  function openSelected() {
    ensurePopupSelection()
    var note = selectedNote()
    if (note) openFull({ path: note.path, focus: "reader" })
    else openFull({})
  }

  function handlePopupKey(event) {
    noteHeldModifiers(event, true)
    if (isModifierKey(event.key)) {
      if (isHintModifierKey(event.key)) shortcutHintsActive = true
      event.accepted = true
      return
    }

    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var plain = !ctrl && !shift && !alt
    var text = String(event.text || "").toLowerCase()

    if (event.key === Qt.Key_Slash && ctrl)
      root.shortcutHintsActive = !root.shortcutHintsActive
    else if (event.key === Qt.Key_Escape) closePopup()
    else if (plain && text === "q") closePopup()
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        || (plain && text === "o")) openSelected()
    else if (plain && text === "p") openFull({})
    else if (plain && text === "t") openFull({ today: true })
    else if (plain && (text === "/" || event.key === Qt.Key_Slash)) {
      searchField.forceActiveFocus()
      searchField.selectAll()
    } else if (event.key === Qt.Key_Down || (plain && text === "j")) {
      movePopupSelection(1)
    } else if (event.key === Qt.Key_Up || (plain && text === "k")) {
      movePopupSelection(-1)
    } else return

    event.accepted = true
  }

  function noteHeldModifiers(event, pressed) {
    var reported = Number(event.modifiers) || 0
    var changed = hintModifierFlag(event.key)
    if (changed !== 0)
      heldModifierFlags = pressed ? (reported | changed) : (reported & ~changed)
    else if (pressed)
      heldModifierFlags = reported
  }

  function isModifierKey(key) {
    return key === Qt.Key_Control || key === Qt.Key_Shift
      || key === Qt.Key_Alt || key === Qt.Key_AltGr || key === Qt.Key_Meta
  }

  function isHintModifierKey(key) {
    return key === Qt.Key_Control || key === Qt.Key_Shift
      || key === Qt.Key_Alt || key === Qt.Key_AltGr
  }

  function hintModifierFlag(key) {
    if (key === Qt.Key_Control) return Qt.ControlModifier
    if (key === Qt.Key_Shift) return Qt.ShiftModifier
    if (key === Qt.Key_Alt || key === Qt.Key_AltGr) return Qt.AltModifier
    return 0
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱓵"
    tooltipText: "Vault · Super+Alt+V"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openFull({ today: true })
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: popupKeyCatcher
    contentWidth: fittedContentWidth(Style.space(360))
    contentHeight: fittedContentHeight(contentColumn.implicitHeight)

    // Keep keyboard focus on a stable item. The list and search field can
    // change focus during navigation, but this catcher remains the popup's
    // fallback target whenever the surface opens.
    PanelKeyCatcher {
      id: popupKeyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onActiveFocusChanged: if (!activeFocus) root.heldModifierFlags = 0
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.movePopupSelection(dy)
      }
      onActivateRequested: root.openSelected()
      onCloseRequested: root.closePopup()
      onTextKey: function(text) {
        var key = String(text || "").toLowerCase()
        if (key === "q") root.closePopup()
        else if (key === "o") root.openSelected()
        else if (key === "p") root.openFull({})
        else if (key === "t") root.openFull({ today: true })
        else if (key === "/") {
          searchField.forceActiveFocus()
          searchField.selectAll()
        }
      }
    }

    Column {
      id: contentColumn
      anchors.fill: parent
        spacing: Style.space(8)

        VaultSetup {
          width: parent.width
          visible: !root.vaultConfigured
          onSubmitted: function(path) { root.saveVaultPath(path) }
        }

      TextField {
        id: searchField
        visible: root.vaultConfigured
        width: parent.width
        foreground: root.foreground
        placeholderText: "Search vault…"
        onTextChanged: if (root.vault) root.vault.setQuery(text)
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.noteHeldModifiers(event, true)
          if (root.isModifierKey(event.key)) {
            if (root.isHintModifierKey(event.key)) root.shortcutHintsActive = true
            event.accepted = true
            return
          }
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            text = ""
            noteList.forceActiveFocus()
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            noteList.forceActiveFocus()
            event.accepted = true
          } else if (event.key === Qt.Key_Slash && ctrl) {
            root.shortcutHintsActive = !root.shortcutHintsActive
            event.accepted = true
          }
        }
        Keys.onReleased: function(event) {
          root.noteHeldModifiers(event, false)
          if (root.isHintModifierKey(event.key)) event.accepted = true
        }
        onAccepted: {
          root.openSelected()
        }
        KeyHint {
          sequences: ["/"]
          showWash: searchField.activeFocus
        }
      }

      ListView {
        id: noteList
        visible: root.vaultConfigured
        width: parent.width
        height: Math.min(Style.space(300), Math.max(Style.space(34), contentHeight))
        clip: true
        model: root.popupNotes
        currentIndex: root.popupIndex
        keyNavigationEnabled: true
        onCurrentIndexChanged: root.popupIndex = currentIndex

        delegate: NoteRow {
          required property var modelData
          required property int index
          width: noteList.width
          compact: true
          foreground: root.foreground
          title: modelData.title
          folder: modelData.folder
          age: Vault.relativeTime(modelData.mtime, Date.now() / 1000)
          selected: index === root.popupIndex
          onPressed: root.selectPopupIndex(index)
          onActivated: {
            root.selectPopupIndex(index)
            root.openSelected()
          }

          KeyHint {
            sequences: ["Enter"]
            active: root.shortcutHintsActive && index === root.popupIndex
            showWash: false
          }
        }

        Keys.onPressed: function(event) { root.handlePopupKey(event) }
        Keys.onReleased: function(event) {
          root.noteHeldModifiers(event, false)
          if (root.isHintModifierKey(event.key)) event.accepted = true
        }
      }

      Text {
        width: parent.width
        visible: root.vaultConfigured
          && (!root.vault || root.vault.notes.length === 0)
        text: root.vault && root.vault.searching ? "Searching…" : "No notes"
        color: root.secondary
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
      }

      Rectangle {
        width: parent.width
        visible: root.showBindTip && root.vaultConfigured
        height: visible ? bindTip.implicitHeight + Style.space(12) : 0
        color: Util.alpha(root.foreground, 0.08)

        Text {
          id: bindTip
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.shortcutSuggestionText()
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.8
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      PanelSeparator { width: parent.width }

      Row {
        visible: root.vaultConfigured
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width - navHintSlot.width - todayButton.width
            - fullButton.width - parent.spacing * 3
          anchors.verticalCenter: parent.verticalCenter
          text: root.selectedLabel
          textFormat: Text.PlainText
          color: root.secondary
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideLeft
        }

        Item {
          id: navHintSlot
          width: Style.space(42)
          height: parent.height

          KeyHint {
            sequences: ["J", "K"]
            active: root.shortcutHintsActive && root.popupOpen
            showWash: false
          }
        }

        Button {
          id: todayButton
          text: "Today"
          foreground: root.foreground
          tooltipText: "Open today's note · T"
          onClicked: root.openFull({ today: true })
          KeyHint { sequences: ["T"] }
        }

        Button {
          id: fullButton
          text: "Panel"
          foreground: root.foreground
          tooltipText: "Open full panel · P"
          onClicked: root.openFull({})
          KeyHint { sequences: ["P"] }
        }
      }
    }
  }
}
