import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "Vault.js" as Vault
import "EditorMutations.js" as EditorMutations

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property var settings: ({})
  property bool opened: false
  property string moduleName: "harbefas.vault"

  property string currentPath: ""
  property string currentTitle: ""
  property string draft: ""
  property bool editing: false
  property bool dirty: false
  property string status: ""
  property bool shortcutHintsActive: false
  property int listIndex: -1
  property int heldModifierFlags: 0
  property string focusRegion: "search"

  // One hue, two weights. Anything secondary is the same foreground at lower
  // opacity — never a second colour.
  readonly property color foreground: Color.foreground
  readonly property color secondary: Util.alpha(foreground, 0.55)
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

  // Large notes can make Qt's MarkdownText take a moment to lay out. The reader
  // still renders the full note; this threshold only decides when to show a
  // small performance warning.
  readonly property int largeNoteThreshold: 200000
  readonly property bool largeNote: draft.length > largeNoteThreshold

  readonly property var notes: service ? service.notes : []
  readonly property bool vaultConfigured: service && service.vaultConfigured

  // Frontmatter is lifted out of the prose and drawn as a header; wikilinks
  // become anchors so they can be followed. These are refreshed manually so a
  // large note is not reparsed and re-rendered on every editor keystroke.
  property var parsed: ({ fields: {}, body: "" })
  property var noteTags: []
  property string noteFolder: ""
  property int noteWords: 0
  property int noteMinutes: 0
  property string noteMeta: ""
  property string rendered: ""
  property string pendingRenderBody: ""
  property var blocks: []

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { if (payloadJson) payload = JSON.parse(payloadJson) } catch (e) {}
    var targeted = payload.focus === "reader"
      || (typeof payload.path === "string" && payload.path !== "")
    if (service) {
      if (payload.settings && typeof payload.settings === "object")
        settings = payload.settings
      service.applySettings(payload.settings)
      service.refresh()
    }
    shortcutHintsActive = payload.shortcutLatch !== false
    opened = true
    focusRegion = targeted ? "reader" : "search"

    if (typeof payload.path === "string" && payload.path !== "")
      selectPath(payload.path)
    else if (currentPath === "" && notes.length > 0) selectPath(notes[0].path)

    if (payload.action === "new") startCreate()
    else if (payload.action === "daily") openDaily()

    Qt.callLater(function() {
      if (payload.action === "new" || payload.action === "daily") return
      if (targeted) focusReader()
      else focusSearch()
    })
  }

  function close() {
    // A close from the host must not drop an unsaved edit on the floor.
    if (dirty) saveDraft()
    heldModifierFlags = 0
    opened = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("harbefas.vault")
    else close()
  }

  onNotesChanged: {
    if (currentPath === "" && notes.length > 0) selectPath(notes[0].path)
    ensureListSelection()
  }
  onCurrentPathChanged: ensureListSelection()

  // The editor takes the draft on entry rather than binding to it: the binding
  // would be broken by the first keystroke anyway, since typing writes back
  // into draft.
  onEditingChanged: {
    if (editing) {
      renderTimer.stop()
      editor.text = draft
    } else {
      refreshReader(true)
      Qt.callLater(function() { focusReader() })
    }
  }

  // ------------------------------------------------------------------ notes

  function selectPath(path) {
    if (!path || path === currentPath) return
    if (dirty) saveDraft()
    currentPath = path
    currentTitle = Vault.noteTitle(path)
    externalChanged = false
    externalText = ""
    editing = false
    clearReader()
    noteFile.path = path
    noteFile.reload()
    ensureListSelection()
  }

  FileView {
    id: noteFile
    watchChanges: true
    printErrors: false

    onLoaded: {
      // A change on disk while editing would silently discard the draft, so an
      // in-progress edit keeps what the user typed and the conflict is handed
      // to them instead. The vault commits itself every minute, so this fires
      // for real: another editor, a sync, a script.
      if (root.editing && root.dirty) {
        var onDisk = text()
        if (onDisk !== root.draft) {
          root.externalText = onDisk
          root.externalChanged = true
        }
        return
      }
      root.externalChanged = false
      root.draft = text()
      if (root.editing) editor.text = root.draft
      root.dirty = false
      root.refreshReader(!root.editing)
      if (root.focusRegion === "reader")
        Qt.callLater(function() { root.focusReader() })
    }
    onLoadFailed: {
      root.draft = ""
      root.clearReader()
      root.status = "Could not read the note."
    }
  }

  property bool externalChanged: false
  property string externalText: ""

  function reloadExternal() {
    externalChanged = false
    draft = externalText
    editor.text = draft
    dirty = false
    refreshReader(!editing)
    status = "Reloaded from disk"
    statusTimer.restart()
  }

  function keepDraft() {
    externalChanged = false
    externalText = ""
    // The draft is still dirty, so the next save wins over the disk copy.
    autosave.restart()
  }

  function saveDraft() {
    if (!dirty || currentPath === "") return
    // An unresolved conflict must not be overwritten by the autosave timer.
    if (externalChanged) return
    noteFile.setText(draft)
    dirty = false
    status = "Saved"
    statusTimer.restart()
  }

  Timer {
    id: statusTimer
    interval: 2000
    onTriggered: root.status = ""
  }

  // Autosave keeps the vault's own minute-by-minute git commits meaningful
  // without needing Ctrl+S after every keystroke.
  Timer {
    id: autosave
    interval: 1500
    onTriggered: root.saveDraft()
  }

  Timer {
    id: renderTimer
    interval: root.largeNote ? 250 : 20
    repeat: false
    onTriggered: root.rendered = Vault.renderMarkdown(root.pendingRenderBody,
      String(root.foreground))
  }

  function clearReader() {
    renderTimer.stop()
    parsed = ({ fields: {}, body: "" })
    noteTags = []
    noteFolder = ""
    noteWords = 0
    noteMinutes = 0
    noteMeta = ""
    pendingRenderBody = ""
    rendered = ""
    blocks = []
  }

  function refreshReader(renderBody) {
    var nextParsed = Vault.splitFrontmatter(draft)
    parsed = nextParsed
    noteTags = Vault.frontmatterTags(nextParsed.fields)
    noteFolder = service ? Vault.relativePath(currentPath, service.resolvedVault) : ""
    noteWords = Vault.wordCount(nextParsed.body)
    noteMinutes = Vault.readingMinutes(noteWords)
    noteMeta = Vault.noteMeta(noteFolder, noteWords, noteMinutes)
    blocks = Vault.parseMarkdownBlocks(nextParsed.body, String(root.foreground))
    if (renderBody === false) return
    pendingRenderBody = nextParsed.body
    renderTimer.restart()
  }

  // A vault:// link is a wikilink; anything else belongs to the browser. An
  // unresolved name is reported instead of failing silently, since a broken
  // link usually means the note has not been written yet.
  function followLink(link) {
    var name = Vault.wikilinkTarget(link)
    if (name === "") { Qt.openUrlExternally(link); return }
    var path = service ? service.resolveNote(name) : ""
    if (path !== "") { selectPath(path); return }
    status = "Note not found: " + name
    statusTimer.restart()
  }

  function noteIndex(path) {
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].path === path) return i
    }
    return -1
  }

  function ensureListSelection() {
    if (!notes.length) {
      listIndex = -1
      return
    }
    if (listIndex >= 0 && listIndex < notes.length) return
    var current = noteIndex(currentPath)
    if (current >= 0) {
      listIndex = current
      return
    }
    if (listIndex < 0) listIndex = 0
    if (listIndex >= notes.length) listIndex = notes.length - 1
  }

  function moveListSelection(delta) {
    if (!notes.length) return
    ensureListSelection()
    listIndex = (listIndex + (delta < 0 ? -1 : 1) + notes.length) % notes.length
    noteList.currentIndex = listIndex
    noteList.positionViewAtIndex(listIndex, ListView.Contain)
    noteList.forceActiveFocus()
  }

  function focusSearch() {
    noteList.focus = false
    keyScope.focus = false
    focusRegion = "search"
    searchField.forceActiveFocus()
  }

  function focusList() {
    ensureListSelection()
    searchField.focus = false
    editor.focus = false
    keyScope.focus = false
    focusRegion = "list"
    noteList.currentIndex = listIndex
    noteList.forceActiveFocus()
  }

  function focusFirstNote() {
    if (!notes.length) {
      focusList()
      return
    }
    listIndex = 0
    noteList.positionViewAtIndex(0, ListView.Contain)
    focusList()
  }

  function focusReader() {
    searchField.focus = false
    editor.focus = false
    noteList.focus = false
    focusRegion = "reader"
    keyScope.forceActiveFocus()
  }

  function readerFlickable() {
    return readerScroll
  }

  function readerScrollTo(value) {
    var flickable = readerFlickable()
    if (flickable && flickable.contentY !== undefined) {
      var minimum = Number(flickable.originY) || 0
      var maximum = Math.max(minimum,
        minimum + Math.max(0, Number(flickable.contentHeight) || 0)
          - Math.max(0, Number(flickable.height) || 0))
      var next = Math.max(minimum, Math.min(maximum, Number(value) || 0))
      if (typeof flickable.cancelFlick === "function") flickable.cancelFlick()
      var changed = Math.abs(flickable.contentY - next) > 0.01
      flickable.contentY = next
      return changed
    }

    var scrollbar = readerScroll.ScrollBar.vertical
    if (!scrollbar) return false
    var barMaximum = Math.max(0, 1 - (Number(scrollbar.size) || 0))
    var barNext = Math.max(0, Math.min(barMaximum, Number(value) || 0))
    var barChanged = Math.abs(scrollbar.position - barNext) > 0.001
    scrollbar.position = barNext
    return barChanged
  }

  function moveReader(delta) {
    var flickable = readerFlickable()
    if (flickable && flickable.contentY !== undefined)
      return readerScrollTo(flickable.contentY + delta)

    var scrollbar = readerScroll.ScrollBar.vertical
    if (!scrollbar) return false
    var step = Math.max(0.025, (Number(scrollbar.size) || 0.1)
      * (Math.abs(delta) > 100 ? 0.86 : 0.12))
    return readerScrollTo(scrollbar.position + (delta < 0 ? -step : step))
  }

  function navigateReader(event) {
    if (editing || focusRegion !== "reader" || currentPath === "") return false

    var plain = (event.modifiers & (Qt.ControlModifier | Qt.ShiftModifier
      | Qt.AltModifier | Qt.MetaModifier)) === 0
    if (!plain) return false

    var flickable = readerFlickable()
    if (!flickable) return false
    var page = Math.max(1, Number(flickable.height) || 0) * 0.86
    var step = Math.max(24, Style.space(5))

    if (event.key === Qt.Key_Down || String(event.text || "").toLowerCase() === "j")
      return moveReader(step)
    if (event.key === Qt.Key_Up || String(event.text || "").toLowerCase() === "k")
      return moveReader(-step)
    if (event.key === Qt.Key_PageDown) return moveReader(page)
    if (event.key === Qt.Key_PageUp) return moveReader(-page)
    if (event.key === Qt.Key_Home) return readerScrollTo(0)
    if (event.key === Qt.Key_End)
      return readerScrollTo((Number(flickable.contentHeight) || 0)
        - (Number(flickable.height) || 0))
    return false
  }

  function selectListSelection() {
    ensureListSelection()
    if (listIndex >= 0 && listIndex < notes.length)
      selectPath(notes[listIndex].path)
    focusReader()
  }

  function textInputFocused() {
    return searchField.activeFocus || editor.activeFocus || newNoteField.activeFocus
  }

  function activateSearch() {
    focusSearch()
    searchField.selectAll()
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

  function toggleEditing() {
    if (currentPath === "") return
    if (editing) saveDraft()
    editing = !editing
    if (editing) Qt.callLater(function() { editor.forceActiveFocus() })
  }

  function saveVaultPath(path) {
    var value = String(path || "").trim()
    if (!value || !root.service) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.vaultPath = value
    root.settings = entry
    root.service.applySettings(entry)
    if (root.bar && root.bar.shell
        && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    root.service.refresh()
  }

  // ------------------------------------------------------------ new notes

  property bool creating: false
  property string pendingCreate: ""

  function startCreate() {
    if (!vaultConfigured) return
    creating = true
  }

  function cancelCreate() {
    creating = false
    focusList()
  }

  function submitCreate(name) {
    var path = Vault.newNotePath(service ? service.resolvedVault : "", name)
    if (path === "") return
    creating = false
    createNote(path, Vault.noteTemplate(Vault.noteTitle(path)))
  }

  function openDaily() {
    if (!service || !vaultConfigured) return
    createNote(service.dailyPath(), Vault.dailyTemplate(new Date()))
  }

  // A shell does the work so the parent folders come along, and an existing
  // note is opened untouched instead of being overwritten by the template.
  function createNote(path, template) {
    if (path === "" || createProcess.running) return
    pendingCreate = path
    createProcess.command = ["sh", "-c",
      'mkdir -p "$(dirname "$1")" && { [ -e "$1" ] || printf %s "$2" > "$1"; }',
      "sh", path, template]
    createProcess.running = true
  }

  Process {
    id: createProcess
    running: false

    onExited: function(exitCode) {
      var path = root.pendingCreate
      root.pendingCreate = ""
      if (exitCode !== 0 || path === "") {
        root.status = "Could not create the note."
        statusTimer.restart()
        return
      }
      if (root.service) root.service.refresh()
      root.selectPath(path)
      root.editing = true
      Qt.callLater(function() { editor.forceActiveFocus() })
    }
  }

  function openExternal() {
    if (currentPath === "") return
    if (dirty) saveDraft()
    Quickshell.execDetached(["xdg-open", currentPath])
    status = "Opening note"
    statusTimer.restart()
  }

  // ------------------------------------------------------------------- IPC

  // ------------------------------------------------------------------- view

  FloatingWindow {
    id: window
    visible: root.opened
    title: "Vault"
    color: Color.background
    implicitWidth: 1100
    implicitHeight: 650
    minimumSize: Qt.size(720, 480)

    onVisibleChanged: {
      if (!visible && root.opened) root.requestClose()
      else if (visible && root.opened && root.focusRegion === "reader")
        Qt.callLater(function() { root.focusReader() })
    }

    FocusScope {
      id: keyScope
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      Keys.onShortcutOverride: function(event) {
        if (root.textInputFocused()) return
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
            || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab
            || event.key === Qt.Key_Escape || event.key === Qt.Key_Up
            || event.key === Qt.Key_Down || event.key === Qt.Key_PageUp
            || event.key === Qt.Key_PageDown || event.key === Qt.Key_Home
            || event.key === Qt.Key_End
            || String(event.text || "").toLowerCase() === "j"
            || String(event.text || "").toLowerCase() === "k")
          event.accepted = true
      }

      Keys.onPressed: function(event) {
        root.noteHeldModifiers(event, true)
        if (root.isModifierKey(event.key)) {
          if (root.isHintModifierKey(event.key)) root.shortcutHintsActive = true
          event.accepted = true
          return
        }

        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0
        var alt = (event.modifiers & Qt.AltModifier) !== 0
        var plain = !ctrl && !shift && !alt
        var text = String(event.text || "").toLowerCase()

        if (event.key === Qt.Key_N && ctrl) {
          root.startCreate()
          event.accepted = true
        } else if (event.key === Qt.Key_D && ctrl) {
          root.openDaily()
          event.accepted = true
        } else if (plain && !root.textInputFocused() && text === "n") {
          root.startCreate()
          event.accepted = true
        } else if (plain && !root.textInputFocused() && text === "d") {
          root.openDaily()
          event.accepted = true
        } else if (event.key === Qt.Key_S && ctrl) {
          root.saveDraft()
          event.accepted = true
        } else if (event.key === Qt.Key_E && ctrl) {
          root.toggleEditing()
          event.accepted = true
        } else if (event.key === Qt.Key_O && ctrl) {
          root.openExternal()
          event.accepted = true
        } else if (plain && !root.textInputFocused() && text === "o") {
          root.openExternal()
          event.accepted = true
        } else if (event.key === Qt.Key_F && ctrl) {
          root.activateSearch()
          event.accepted = true
        } else if (event.key === Qt.Key_Slash && ctrl) {
          root.shortcutHintsActive = !root.shortcutHintsActive
          event.accepted = true
        } else if (plain && !root.textInputFocused()
            && (event.key === Qt.Key_Slash || text === "/")) {
          root.activateSearch()
          event.accepted = true
        } else if (plain && !root.textInputFocused() && text === "e") {
          root.toggleEditing()
          event.accepted = true
        } else if (plain && !root.textInputFocused() && text === "q") {
          root.requestClose()
          event.accepted = true
        } else if (plain && event.key === Qt.Key_Tab
            && root.focusRegion === "reader") {
          root.focusList()
          event.accepted = true
        } else if (root.navigateReader(event)) {
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          if (root.creating) root.cancelCreate()
          else if (root.editing) { root.saveDraft(); root.editing = false }
          else if (searchField.activeFocus) root.focusList()
          else if (root.focusRegion === "reader") root.focusFirstNote()
          else root.requestClose()
          event.accepted = true
        }
      }
      Keys.onReleased: function(event) {
        root.noteHeldModifiers(event, false)
        if (root.isHintModifierKey(event.key)) event.accepted = true
      }

      Rectangle {
        anchors.fill: parent
        color: Color.background
        visible: !root.vaultConfigured
        z: 20

        VaultSetup {
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(48), Style.space(620))
          foreground: root.foreground
          onSubmitted: function(path) { root.saveVaultPath(path) }
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(14)
        spacing: Style.space(10)

        // ---- header: search and daily note
        Row {
          id: header
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: searchField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Search vault…"
            onTextChanged: if (root.service) root.service.setQuery(text)
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
                root.focusList()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.focusList()
                event.accepted = true
              } else if (event.key === Qt.Key_Enter
                  || event.key === Qt.Key_Return) {
                root.selectListSelection()
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
            KeyHint {
              sequences: ["/"]
              showWash: searchField.activeFocus
            }
          }

        }

        // ---- body: note list + reader/editor
        Row {
          width: parent.width
          height: parent.height - header.height - footer.height - parent.spacing * 2
          spacing: Style.space(12)

          BorderSurface {
            width: Style.space(280)
            height: parent.height
            // Rectangle defaults to white; both surfaces take the kit's fill
            // and border so they sit on the theme instead of punching a hole.
            color: Style.normalFillFor(root.foreground, root.foreground)
            borderSpec: Border.controlSpec("normal", root.foreground, root.foreground)

            ListView {
              id: noteList
              anchors.fill: parent
              anchors.margins: Style.space(4)
              clip: true
              model: root.notes
              currentIndex: root.listIndex
              // Navigation is handled below so Qt cannot advance twice.
              keyNavigationEnabled: false
              onCurrentIndexChanged: root.listIndex = currentIndex

              delegate: NoteRow {
                required property var modelData
                required property int index
                width: noteList.width
                foreground: root.foreground
                title: modelData.title
                folder: modelData.folder
                age: Vault.relativeTime(modelData.mtime, Date.now() / 1000)
                selected: noteList.activeFocus
                  ? index === root.listIndex
                  : modelData.path === root.currentPath
                onPressed: {
                  root.listIndex = index
                  noteList.forceActiveFocus()
                }
                onActivated: {
                  root.selectPath(modelData.path)
                  root.focusReader()
                }

                KeyHint {
                  sequences: ["Enter"]
                  navHint: "J/K"
                  active: root.shortcutHintsActive
                    && noteList.activeFocus && index === root.listIndex
                  showWash: false
                }
              }

              Keys.onPressed: function(event) {
                root.noteHeldModifiers(event, true)
                if (root.isModifierKey(event.key)) {
                  if (root.isHintModifierKey(event.key)) root.shortcutHintsActive = true
                  event.accepted = true
                  return
                }

                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                var alt = (event.modifiers & Qt.AltModifier) !== 0
                var plain = !ctrl && !shift && !alt
                var text = String(event.text || "").toLowerCase()

                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.selectListSelection()
                } else if (event.key === Qt.Key_Down || (plain && text === "j")) {
                  root.moveListSelection(1)
                } else if (event.key === Qt.Key_Up || (plain && text === "k")) {
                  root.moveListSelection(-1)
                } else if (event.key === Qt.Key_Tab) {
                  root.focusReader()
                } else if (event.key === Qt.Key_Home) {
                  root.listIndex = 0
                  noteList.positionViewAtIndex(0, ListView.Contain)
                } else if (event.key === Qt.Key_End) {
                  root.listIndex = Math.max(0, root.notes.length - 1)
                  noteList.positionViewAtIndex(root.listIndex, ListView.Contain)
                } else if (event.key === Qt.Key_Escape) {
                  root.requestClose()
                } else return

                event.accepted = true
              }
              Keys.onReleased: function(event) {
                root.noteHeldModifiers(event, false)
                if (root.isHintModifierKey(event.key)) event.accepted = true
              }
            }

            Text {
              readonly property string readError:
                root.service && root.service.error ? root.service.error : ""

              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              visible: root.notes.length === 0
              // An empty vault and a vault that could not be read looked
              // exactly alike before.
              text: readError !== "" ? "Could not read the vault.\n" + readError
                : (root.service && root.service.searching ? "Searching…" : "No notes")
              textFormat: Text.PlainText
              color: root.secondary
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          BorderSurface {
            width: parent.width - Style.space(280) - parent.spacing
            height: parent.height
            color: Style.normalFillFor(root.foreground, root.foreground)
            borderSpec: Border.controlSpec("normal", root.foreground, root.foreground)

            Column {
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Row {
                id: noteHeader
                width: parent.width
                height: Math.max(titleBlock.implicitHeight, openFileButton.implicitHeight,
                  hintButton.implicitHeight, modeButton.implicitHeight,
                  newButton.implicitHeight, dailyButton.implicitHeight)
                spacing: Style.space(8)

                Column {
                  id: titleBlock
                  width: parent.width - openFileButton.width - hintButton.width
                    - modeButton.width - newButton.width - dailyButton.width
                    - parent.spacing * 5
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    text: root.currentTitle !== "" ? root.currentTitle : "No note open"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.noteMeta
                    textFormat: Text.PlainText
                    visible: root.noteMeta !== ""
                    color: root.secondary
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Button {
                  id: newButton
                  text: "New"
                  foreground: root.foreground
                  enabled: root.vaultConfigured
                  tooltipText: "Create a note · N or Ctrl+N"
                  onClicked: root.startCreate()
                  KeyHint { sequences: ["N", "Ctrl+N"] }
                }

                Button {
                  id: dailyButton
                  text: "Today"
                  foreground: root.foreground
                  enabled: root.vaultConfigured
                  tooltipText: "Open today's daily note · D or Ctrl+D"
                  onClicked: root.openDaily()
                  KeyHint { sequences: ["D", "Ctrl+D"] }
                }

                Button {
                  id: openFileButton
                  text: "File"
                  foreground: root.foreground
                  enabled: root.currentPath !== ""
                  tooltipText: "Open note in the default app · O or Ctrl+O"
                  onClicked: root.openExternal()
                  KeyHint { sequences: ["O", "Ctrl+O"] }
                }

                Button {
                  id: hintButton
                  text: "?"
                  foreground: root.foreground
                  tooltipText: "Show shortcuts · Ctrl+/"
                  onClicked: root.shortcutHintsActive = !root.shortcutHintsActive
                  KeyHint { sequences: ["Ctrl+/"] }
                }

                Button {
                  id: modeButton
                  text: root.editing ? "Read" : "Edit"
                  foreground: root.foreground
                  // Large notes can be slower in TextArea, but editing uses the
                  // complete draft.
                  enabled: root.currentPath !== ""
                  tooltipText: root.editing
                    ? "Return to reading · E or Ctrl+E"
                    : "Edit the full Markdown note · E or Ctrl+E"
                  onClicked: root.toggleEditing()
                  KeyHint { sequences: ["E", "Ctrl+E"] }
                }
              }

              // Name prompt for a new note. A `/` in the name creates the
              // folders, so `Pessoal/Ideias` works without leaving the panel.
              TextField {
                id: newNoteField
                width: parent.width
                visible: root.creating
                placeholderText: "New note name — Folder/Name creates the folder"
                foreground: root.foreground
                onAccepted: root.submitCreate(text)
                onVisibleChanged: {
                  if (!visible) return
                  text = ""
                  Qt.callLater(function() { newNoteField.forceActiveFocus() })
                }
                Keys.onEscapePressed: root.cancelCreate()
              }

              // Frontmatter tags, drawn as chips instead of raw YAML.
              Flow {
                id: tagRow
                width: parent.width
                visible: root.noteTags.length > 0
                spacing: Style.space(6)

                Repeater {
                  model: root.noteTags

                  BorderSurface {
                    required property string modelData
                    implicitWidth: tagText.implicitWidth + Style.space(14)
                    implicitHeight: tagText.implicitHeight + Style.space(6)
                    color: Util.alpha(root.foreground, 0.06)
                    borderSpec: Border.controlSpec("normal", root.foreground, root.foreground)

                    Text {
                      id: tagText
                      anchors.centerIn: parent
                    text: "#" + parent.modelData
                    textFormat: Text.PlainText
                      color: root.secondary
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              PanelSeparator { width: parent.width }

              Text {
                id: oversizedNotice
                width: parent.width
                visible: root.largeNote
                text: "Large note (" + Math.round(root.draft.length / 1024)
                  + " KB). Rendering the full note may take longer to read or edit."
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.secondary
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              // The note changed on disk under an unsaved draft. Autosave is
              // held until this is answered, so neither copy is lost.
              Row {
                id: conflictRow
                width: parent.width
                visible: root.externalChanged
                spacing: Style.space(8)

                Text {
                  width: parent.width - reloadButton.width - keepButton.width
                    - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  text: "This note changed on disk. Reloading discards your unsaved edits."
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Button {
                  id: keepButton
                  text: "Keep mine"
                  foreground: root.foreground
                  tooltipText: "Discard the version on disk on the next save"
                  onClicked: root.keepDraft()
                }

                Button {
                  id: reloadButton
                  text: "Reload"
                  foreground: root.foreground
                  tooltipText: "Replace the draft with the version on disk"
                  onClicked: root.reloadExternal()
                }
              }

              // Keep the reader's Flickable explicit. This makes the content
              // height and keyboard scrolling reliable for very large notes.
              Item {
                id: contentArea
                width: parent.width
                height: parent.height - noteHeader.height - Style.space(1)
                  - (root.noteTags.length > 0 ? tagRow.implicitHeight + parent.spacing : 0)
                  - (root.largeNote ? oversizedNotice.implicitHeight + parent.spacing : 0)
                  - (root.creating ? newNoteField.implicitHeight + parent.spacing : 0)
                  - (root.externalChanged ? conflictRow.implicitHeight + parent.spacing : 0)
                  - parent.spacing * 3

                Flickable {
                  id: readerScroll
                  anchors.fill: parent
                  visible: !root.editing
                  clip: true
                  contentWidth: width
                  contentHeight: readerContent.implicitHeight
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                  }

                  Column {
                    id: readerContent
                    width: readerScroll.width
                    spacing: Style.space(10)

                    Repeater {
                      model: root.blocks

                      delegate: Item {
                        required property var modelData
                        width: readerContent.width
                        implicitHeight: block.implicitHeight

                        Column {
                          id: block
                          x: Style.space(12)
                          width: parent.width - Style.space(24)
                          spacing: Style.space(4)

                          Text {
                            width: parent.width
                            visible: modelData.type === "heading"
                            text: modelData.text
                            textFormat: Text.MarkdownText
                            color: root.foreground
                            font.family: Style.font.family
                            font.bold: true
                            font.pixelSize: modelData.level === 1
                              ? Style.font.title
                              : (modelData.level <= 3
                                ? Style.font.subtitle : Style.font.body)
                            wrapMode: Text.Wrap
                            linkColor: root.foreground
                            lineHeight: 1.15
                            lineHeightMode: Text.ProportionalHeight
                            onLinkActivated: function(link) { root.followLink(link) }
                          }

                          Text {
                            width: parent.width
                            visible: modelData.type === "paragraph"
                              || modelData.type === "list"
                              || modelData.type === "quote"
                            text: modelData.text
                            textFormat: Text.MarkdownText
                            color: modelData.type === "quote"
                              ? root.secondary : root.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.subtitle
                            leftPadding: modelData.type === "quote"
                              ? Style.space(12) : 0
                            wrapMode: Text.Wrap
                            linkColor: root.foreground
                            lineHeight: 1.35
                            lineHeightMode: Text.ProportionalHeight
                            onLinkActivated: function(link) { root.followLink(link) }
                          }

                          BorderSurface {
                            width: parent.width
                            visible: modelData.type === "code"
                            implicitHeight: codeText.implicitHeight
                              + Style.space(16)
                            color: Util.alpha(root.foreground, 0.07)
                            borderSpec: Border.controlSpec("normal",
                              root.foreground, root.foreground)

                            Text {
                              id: codeText
                              anchors.fill: parent
                              anchors.margins: Style.space(8)
                              text: modelData.text
                              textFormat: Text.PlainText
                              color: root.foreground
                              font.family: Style.font.family
                              font.pixelSize: Style.font.bodySmall
                              wrapMode: Text.Wrap
                            }
                          }

                          BorderSurface {
                            width: parent.width
                            visible: modelData.type === "callout"
                            implicitHeight: calloutText.implicitHeight
                              + Style.space(16)
                            color: Util.alpha(root.foreground, 0.06)
                            borderSpec: Border.controlSpec("normal",
                              root.foreground, root.foreground)

                            Text {
                              id: calloutText
                              anchors.fill: parent
                              anchors.margins: Style.space(8)
                              text: "[" + modelData.kind + "]  " + modelData.text
                              textFormat: Text.MarkdownText
                              color: root.foreground
                              font.family: Style.font.family
                              font.pixelSize: Style.font.subtitle
                              wrapMode: Text.Wrap
                              linkColor: root.foreground
                              lineHeight: 1.3
                              lineHeightMode: Text.ProportionalHeight
                              onLinkActivated: function(link) { root.followLink(link) }
                            }
                          }

                          PanelSeparator {
                            width: parent.width
                            visible: modelData.type === "rule"
                          }
                        }
                      }
                    }
                  }
                }

                KeyHint {
                  sequences: ["PageUp", "PageDown", "Home", "End"]
                    active: root.shortcutHintsActive && !root.editing
                    && root.currentPath !== ""
                  showWash: false
                }

                ScrollView {
                  anchors.fill: parent
                  visible: root.editing
                  clip: true

                  // Raw markdown while editing, so the syntax being typed is
                  // the syntax on screen.
                  TextArea {
                    id: editor
                    wrapMode: TextEdit.Wrap
                    color: root.foreground
                    selectionColor: Util.alpha(root.foreground, 0.25)
                    selectedTextColor: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    background: null

                    // Wraps the selection, or drops the markers around an
                    // empty caret and leaves it between them.
                    function wrapSelection(before, after) {
                      var start = Math.min(selectionStart, selectionEnd)
                      var end = Math.max(selectionStart, selectionEnd)
                      var selected = text.slice(start, end)
                      EditorMutations.replaceRange(editor, start, end,
                        before + selected + after,
                        before.length, before.length + selected.length)
                    }

                    // `[label](url)` with the half the user still has to fill
                    // in left selected.
                    function insertLink() {
                      var start = Math.min(selectionStart, selectionEnd)
                      var end = Math.max(selectionStart, selectionEnd)
                      var label = text.slice(start, end) || "link text"
                      var markdown = "[" + label + "](https://)"
                      if (start === end)
                        EditorMutations.replaceRange(editor, start, end, markdown,
                          1, 1 + label.length)
                      else
                        EditorMutations.replaceRange(editor, start, end, markdown,
                          label.length + 3, markdown.length - 1)
                    }

                    function insertWikilink() {
                      var start = Math.min(selectionStart, selectionEnd)
                      var end = Math.max(selectionStart, selectionEnd)
                      var name = text.slice(start, end)
                      EditorMutations.replaceRange(editor, start, end,
                        "[[" + name + "]]", 2, 2 + name.length)
                    }

                    Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                root.noteHeldModifiers(event, true)
                      if (root.isModifierKey(event.key)) {
                        if (root.isHintModifierKey(event.key))
                          root.shortcutHintsActive = true
                        event.accepted = true
                        return
                      }
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                if (event.key === Qt.Key_Escape) {
                  root.saveDraft()
                  root.editing = false
                        event.accepted = true
                      } else if (event.key === Qt.Key_S && ctrl) {
                        root.saveDraft()
                        event.accepted = true
                      } else if (event.key === Qt.Key_E && ctrl) {
                        root.toggleEditing()
                        event.accepted = true
                      } else if (event.key === Qt.Key_B && ctrl) {
                        editor.wrapSelection("**", "**")
                        event.accepted = true
                      } else if (event.key === Qt.Key_I && ctrl) {
                        editor.wrapSelection("*", "*")
                        event.accepted = true
                      } else if (event.key === Qt.Key_K && ctrl) {
                        editor.insertLink()
                        event.accepted = true
                      } else if (event.key === Qt.Key_L && ctrl) {
                        editor.insertWikilink()
                        event.accepted = true
                      } else if (event.key === Qt.Key_Tab && !shift) {
                        root.focusList()
                        event.accepted = true
                      }
                    }
                    Keys.onReleased: function(event) {
                      root.noteHeldModifiers(event, false)
                      if (root.isHintModifierKey(event.key)) event.accepted = true
                    }
                    KeyHint {
                      sequences: ["Esc", "Ctrl+S", "Ctrl+E", "Ctrl+B", "Ctrl+I",
                        "Ctrl+K", "Ctrl+L"]
                      active: root.shortcutHintsActive && root.editing
                      showWash: false
                    }
                    onTextChanged: {
                      if (!root.editing || text === root.draft) return
                      root.draft = text
                      root.dirty = true
                      autosave.restart()
                    }
                  }
                }
              }
            }
          }
        }

        // ---- footer: path + save state
        Row {
          id: footer
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width - stateLabel.width - navHintSlot.width
              - parent.spacing * 2
            text: root.currentPath
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
              active: root.shortcutHintsActive && !root.editing
                && root.currentPath !== ""
              showWash: false
            }
          }

          Text {
            id: stateLabel
            text: root.status !== "" ? root.status
              : (root.dirty ? "Unsaved" : "")
            textFormat: Text.PlainText
            color: root.secondary
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

}
