import QtQuick
import Quickshell
import Quickshell.Io

import "Vault.js" as Vault

// Shared state for the bar popup and the lazy full panel. Both show the same
// note list, so the listing runs once here rather than once per surface.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "harbefas.vault"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : home + "/.config/omarchy/plugins/harbefas.vault"
  property string vaultPath: ""
  property int recentCount: 40
  readonly property string resolvedVault: vaultPath.trim()
  readonly property bool vaultConfigured: vaultPath.trim() !== ""

  // Every note in the vault, used to resolve wikilinks by title. Cheap to
  // hold: the listing already walked the whole tree.
  property var index: []
  property var recent: []
  property var notes: []
  property var recentMtimes: ({})
  property string query: ""
  property string searchTerm: ""
  property bool searchAgain: false
  property bool searching: false

  // Offer an optional launcher shortcut without ever changing the user's
  // Hyprland configuration. The suggestion disappears once a matching bind
  // is found in either supported configuration format.
  readonly property string suggestedKey: "SUPER + ALT + V"
  readonly property string suggestedBind:
    'o.bind("' + root.suggestedKey + '", "Vault quick view", "omarchy shell -q harbefas.vault.widget toggle")'
  property bool keybindConfigured: false
  property int bindingsScanned: 0
  readonly property bool bindingsReady: root.bindingsScanned >= 2

  function noteBindings(text) {
    // The full panel binding is independent; only the widget binding disables
    // this widget-launcher suggestion.
    if (String(text || "").indexOf("harbefas.vault.widget") >= 0)
      root.keybindConfigured = true
    root.bindingsScanned += 1
  }

  function applySettings(s) {
    if (!s) return
    if (typeof s.vaultPath === "string" && s.vaultPath !== "") vaultPath = s.vaultPath
    var count = Number(s.recentCount)
    if (isFinite(count) && count > 0) recentCount = Math.round(count)
  }

  FileView {
    path: home + "/.config/hypr/bindings.lua"
    watchChanges: true
    onLoaded: root.noteBindings(text())
    onLoadFailed: root.bindingsScanned += 1
  }

  FileView {
    path: home + "/.config/hypr/bindings.conf"
    watchChanges: true
    onLoaded: root.noteBindings(text())
    onLoadFailed: root.bindingsScanned += 1
  }

  // ---------------------------------------------------------------- listing

  function refresh() {
    if (!root.vaultConfigured) return
    if (!listProcess.running) listProcess.running = true
  }

  function setQuery(text) {
    query = String(text || "")
    searchDebounce.restart()
  }

  function runQuery() {
    var term = query.trim()
    if (term === "") {
      searchAgain = false
      notes = recent
      searching = false
      return
    }
    notes = Vault.filterNotes(index, term, recentCount)
    if (searchProcess.running) {
      searchAgain = true
      return
    }
    searchTerm = term
    searching = true
    searchProcess.running = true
  }

  function finishSearch(output) {
    var term = searchTerm
    searching = false
    notes = Vault.mergeSearch(output, index, term, resolvedVault, recentMtimes)
    if (query.trim() !== term) {
      searchAgain = false
      searchDebounce.restart()
    }
  }

  function openWidget() {
    var bar = shell ? shell.bar : null
    return !!bar && typeof bar.summonBarWidget === "function"
      && bar.summonBarWidget(pluginId) === true
  }

  function closeWidget() {
    var bar = shell ? shell.bar : null
    return !!bar && typeof bar.hideBarWidget === "function"
      && bar.hideBarWidget(pluginId) === true
  }

  function isWidgetOpen() {
    var bar = shell ? shell.bar : null
    return !!bar && typeof bar.isBarWidgetOpen === "function"
      && bar.isBarWidgetOpen(pluginId) === true
  }

  Timer {
    id: searchDebounce
    interval: 180
    onTriggered: root.runQuery()
  }

  Process {
    id: listProcess
    running: false
    command: [root.pluginDir + "/bin/bounded-output", "find", root.resolvedVault,
      "-type", "f", "-name", "*.md",
      "-not", "-path", "*/.*", "-printf", "%T@\t%p\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.length > Vault.MAX_PROCESS_OUTPUT) {
          root.index = []
          root.recent = []
          root.notes = []
          root.recentMtimes = ({})
          return
        }
        var all = Vault.parseListing(text, root.resolvedVault, 0)
        var parsed = all.slice(0, root.recentCount)
        root.index = all
        root.recent = parsed
        root.recentMtimes = Vault.mtimeMap(all)
        if (root.query.trim() === "") root.notes = parsed
      }
    }
  }

  Process {
    id: searchProcess
    running: false
    command: [root.pluginDir + "/bin/bounded-output", "rg", "--files-with-matches",
      "--smart-case", "--fixed-strings",
      "--glob", "*.md", "--", root.searchTerm, root.resolvedVault]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text.length > Vault.MAX_PROCESS_OUTPUT) {
          root.finishSearch("")
          return
        }
        root.finishSearch(text)
      }
    }
    // rg exits 1 when nothing matched, which is an empty result, not a fault.
    onExited: {
      if (root.searching) root.finishSearch("")
      if (root.searchAgain) {
        root.searchAgain = false
        root.searchDebounce.restart()
      }
    }
  }

  // --------------------------------------------------------------- daily

  function resolveNote(name) {
    return Vault.resolveNote(name, index)
  }

  function dailyPath() {
    return resolvedVault + "/" + Vault.dailyNotePath(new Date())
  }

  IpcHandler {
    target: root.pluginId + ".widget"

    function open(): string {
      return root.openWidget() ? "opened" : "unavailable"
    }

    function close(): string {
      return root.closeWidget() ? "closed" : "unavailable"
    }

    function show(): string {
      return root.openWidget() ? "opened" : "unavailable"
    }

    function hide(): string {
      return root.closeWidget() ? "closed" : "unavailable"
    }

    function toggle(): string {
      return root.isWidgetOpen()
        ? (root.closeWidget() ? "closed" : "unavailable")
        : (root.openWidget() ? "opened" : "unavailable")
    }
  }

  Component.onCompleted: refresh()
}
