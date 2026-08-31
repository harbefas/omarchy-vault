.pragma library

// Pure helpers for the vault plugin. Kept out of the QML so the path and
// parsing rules can be unit-tested with plain node.

var MONTHS = [
  "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho",
  "Julho", "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro"
]

// The producer applies the byte limit; this second check protects the QML
// boundary if a different producer is configured later.
var MAX_PROCESS_OUTPUT = 4 * 1024 * 1024

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// `dd-mm-yyyy.md` under `Daily Notes/<Mês>/`, and under an extra `<year>/`
// level from 2026 on — the vault reorganised that year and older notes were
// left where they were.
function dailyNotePath(date) {
  var d = date || new Date()
  var year = d.getFullYear()
  var month = MONTHS[d.getMonth()]
  var file = pad2(d.getDate()) + "-" + pad2(d.getMonth() + 1) + "-" + year + ".md"
  var dir = year >= 2026
    ? "Daily Notes/" + year + "/" + month
    : "Daily Notes/" + month
  return dir + "/" + file
}

function baseName(path) {
  var parts = String(path || "").split("/")
  return parts[parts.length - 1] || ""
}

function noteTitle(path) {
  var name = baseName(path)
  var title = name.slice(-3).toLowerCase() === ".md" ? name.slice(0, -3) : name
  return title.slice(0, 512)
}

// Path relative to the vault root, used as the subtitle in the note list so
// two notes with the same name stay distinguishable.
function relativePath(path, vaultPath) {
  var p = String(path || "")
  var root = String(vaultPath || "")
  if (root && p.indexOf(root) === 0) {
    p = p.slice(root.length)
    if (p.charAt(0) === "/") p = p.slice(1)
  }
  var cut = p.lastIndexOf("/")
  return cut === -1 ? "" : p.slice(0, cut).slice(-2048)
}

function safeNotePath(path, vaultPath) {
  var p = String(path || "")
  var root = String(vaultPath || "").replace(/\/+$/, "")
  if (!p || !root || /[\x00-\x1f\x7f]/.test(p)) return false
  if (p.slice(0, root.length + 1) !== root + "/") return false
  if (p.slice(-3).toLowerCase() !== ".md") return false
  return p.length <= 4096
}

// `find -printf "%T@\t%p\n"` output, newest first. Epoch seconds carry a
// fractional part that Number() handles and parseInt() would truncate.
function parseListing(output, vaultPath, limit) {
  var lines = String(output || "").split("\n")
  var notes = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (!line) continue
    var tab = line.indexOf("\t")
    if (tab === -1) continue
    var mtime = Number(line.slice(0, tab))
    var path = line.slice(tab + 1)
    if (!isFinite(mtime) || !safeNotePath(path, vaultPath)) continue
    notes.push({
      path: path,
      title: noteTitle(path),
      folder: relativePath(path, vaultPath),
      mtime: mtime
    })
  }
  notes.sort(function(a, b) { return b.mtime - a.mtime })
  var max = Number(limit)
  return isFinite(max) && max > 0 ? notes.slice(0, max) : notes
}

// `rg --files-with-matches`, one absolute path per line. Ordered by the
// recency map so search results read like the recent list.
function parseSearch(output, vaultPath, mtimes) {
  var lines = String(output || "").split("\n")
  var notes = []
  for (var i = 0; i < lines.length; i++) {
    var path = lines[i].replace(/\r$/, "")
    if (!safeNotePath(path, vaultPath)) continue
    notes.push({
      path: path,
      title: noteTitle(path),
      folder: relativePath(path, vaultPath),
      mtime: (mtimes && mtimes[path]) || 0
    })
  }
  notes.sort(function(a, b) { return b.mtime - a.mtime })
  return notes
}

function queryTokens(query) {
  return String(query || "")
    .replace(/^\s+|\s+$/g, "")
    .toLowerCase()
    .split(/\s+/)
    .filter(function(t) { return t !== "" })
}

function noteMatchesQuery(note, query) {
  var tokens = queryTokens(query)
  if (!tokens.length) return true
  var haystack = [
    note && note.title,
    note && note.folder,
    note && note.path
  ].join(" ").toLowerCase()
  for (var i = 0; i < tokens.length; i++) {
    if (haystack.indexOf(tokens[i]) === -1) return false
  }
  return true
}

function filterNotes(notes, query, limit) {
  if (!notes) return []
  var result = []
  for (var i = 0; i < notes.length; i++) {
    if (!noteMatchesQuery(notes[i], query)) continue
    result.push(notes[i])
    if (limit > 0 && result.length >= limit) break
  }
  return result
}

function mergeSearch(output, index, query, vaultPath, mtimes) {
  var merged = []
  var seen = ({})

  function add(list) {
    for (var i = 0; i < list.length; i++) {
      var note = list[i]
      if (!note || !note.path || seen[note.path]) continue
      seen[note.path] = true
      merged.push(note)
    }
  }

  add(filterNotes(index, query, 0))
  add(parseSearch(output, vaultPath, mtimes))
  merged.sort(function(a, b) { return b.mtime - a.mtime })
  return merged
}

function mtimeMap(notes) {
  var map = ({})
  for (var i = 0; i < notes.length; i++) map[notes[i].path] = notes[i].mtime
  return map
}

function relativeTime(mtime, now) {
  var then = Number(mtime)
  if (!isFinite(then) || then <= 0) return ""
  var seconds = Math.max(0, Math.floor((now || Date.now() / 1000) - then))
  if (seconds < 60) return "now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  if (days < 7) return days + "d"
  var weeks = Math.floor(days / 7)
  if (weeks < 5) return weeks + "w"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "m"
  return Math.floor(days / 365) + "a"
}

// ---------------------------------------------------------------- rendering

// YAML frontmatter is metadata, not prose: it is lifted out of the body and
// shown as a header instead of being dumped as text at the top of the note.
function splitFrontmatter(text) {
  var body = String(text || "")
  if (body.slice(0, 4) !== "---\n") return { fields: {}, body: body }
  var end = body.indexOf("\n---", 3)
  if (end === -1) return { fields: {}, body: body }
  var head = body.slice(4, end)
  var rest = body.slice(end + 4)
  while (rest.charAt(0) === "\n") rest = rest.slice(1)

  var fields = ({})
  var lines = head.split("\n")
  var lastKey = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue
    // `- item` continues the previous key's list.
    var listItem = line.match(/^\s*-\s+(.*)$/)
    if (listItem && lastKey) {
      fields[lastKey] = (fields[lastKey] ? fields[lastKey] + ", " : "") + listItem[1].trim()
      continue
    }
    var pair = line.match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/)
    if (!pair) continue
    lastKey = pair[1]
    fields[lastKey] = pair[2].trim()
  }
  return { fields: fields, body: rest }
}

function frontmatterTags(fields) {
  var raw = fields && (fields.tags || fields.tag)
  if (!raw) return []
  return String(raw)
    .replace(/[\[\]]/g, "")
    .split(",")
    .map(function(t) { return t.trim().replace(/^#/, "").slice(0, 128) })
    .filter(function(t) { return t !== "" })
    .slice(0, 32)
}

function normalizeVaultMarkdown(text) {
  var body = String(text || "")
  body = body.replace(/!\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g,
    function(match, target, alias) {
      return "*Attachment: " + (alias || target).trim() + "*"
    })
  body = body.replace(/(^|\n)([ \t]*[-*]\s+)\[ \]/g, "$1$2☐")
  body = body.replace(/(^|\n)([ \t]*[-*]\s+)\[[xX]\]/g, "$1$2☑")
  body = body.replace(/(^|\n)>\s*\[!([A-Za-z][A-Za-z0-9_-]*)\][+-]?\s*(.*)/g,
    function(match, lead, kind, title) {
      var suffix = String(title || "").trim()
      return lead + "> **" + kind.toUpperCase() + "**"
        + (suffix ? " · " + suffix : "")
    })
  body = body.replace(/==([^=\n][^\n]*?)==/g, "**$1**")
  return body
}

function renderMarkdown(text, color) {
  return linkifyWikilinks(normalizeVaultMarkdown(text), color)
}

// Split the note into stable visual blocks. Qt MarkdownText remains responsible
// for inline formatting, while QML controls spacing and block presentation.
function parseMarkdownBlocks(text, color) {
  var source = String(text || "").replace(/\r\n/g, "\n")
  var lines = source.split("\n")
  var blocks = []
  var paragraph = []
  var list = []
  var code = []
  var inCode = false
  var codeLanguage = ""

  function flushParagraph() {
    if (!paragraph.length) return
    blocks.push({ type: "paragraph", text: renderMarkdown(
      paragraph.join("\n"), color) })
    paragraph = []
  }

  function flushList() {
    if (!list.length) return
    blocks.push({ type: "list", text: renderMarkdown(list.join("\n"), color) })
    list = []
  }

  function flushCode() {
    blocks.push({ type: "code", text: code.join("\n"), language: codeLanguage })
    code = []
    codeLanguage = ""
  }

  function isListLine(line) {
    return /^\s*(?:[-*+]\s+|\d+[.)]\s+)/.test(line)
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var trimmed = line.trim()

    if (inCode) {
      if (/^\s*\x60{3}/.test(line)) {
        flushCode()
        inCode = false
      } else code.push(line)
      continue
    }

    var fence = line.match(/^\s*\x60{3}\s*([A-Za-z0-9_+.-]*)\s*$/)
    if (fence) {
      flushParagraph()
      flushList()
      inCode = true
      codeLanguage = fence[1] || "text"
      continue
    }

    if (trimmed === "") {
      flushParagraph()
      flushList()
      continue
    }

    var heading = line.match(/^\s*(#{1,6})\s+(.+?)\s*#*\s*$/)
    if (heading) {
      flushParagraph()
      flushList()
      blocks.push({
        type: "heading",
        level: heading[1].length,
        text: renderMarkdown(heading[2], color)
      })
      continue
    }

    if (/^\s*(?:---+|___+|\*\s*\*\s*\*)\s*$/.test(line)) {
      flushParagraph()
      flushList()
      blocks.push({ type: "rule", text: "" })
      continue
    }

    var callout = line.match(/^\s*>\s*\[!([A-Za-z][A-Za-z0-9_-]*)\][+-]?\s*(.*)$/)
    if (callout) {
      flushParagraph()
      flushList()
      blocks.push({
        type: "callout",
        kind: callout[1].toUpperCase(),
        text: renderMarkdown(callout[2] || "", color)
      })
      continue
    }

    if (/^\s*>/.test(line)) {
      flushParagraph()
      flushList()
      var quote = []
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        quote.push(lines[i].replace(/^\s*>\s?/, ""))
        i++
      }
      i--
      blocks.push({
        type: "quote",
        text: renderMarkdown(quote.join("\n"), color)
      })
      continue
    }

    if (isListLine(line)) {
      flushParagraph()
    list.push(normalizeVaultMarkdown(line))
      continue
    }

    if (list.length) flushList()
    paragraph.push(line)
  }

  if (inCode) flushCode()
  flushParagraph()
  flushList()
  return blocks
}

function wordCount(text) {
  var plain = String(text || "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`[^`\n]*`/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[#>*_\-[\](){}=|]/g, " ")
  var words = plain.match(/[0-9A-Za-zÀ-ÖØ-öø-ÿ_]+/g)
  return words ? words.length : 0
}

function readingMinutes(words) {
  var count = Number(words) || 0
  return count > 0 ? Math.max(1, Math.ceil(count / 220)) : 0
}

function noteMeta(folder, words, minutes) {
  var parts = []
  if (folder) parts.push(folder)
  if (words > 0) parts.push(words + (words === 1 ? " word" : " words"))
  if (minutes > 0) parts.push(minutes + " min read")
  return parts.join(" · ")
}

// `[[note]]` and `[[note|alias]]` become real markdown links so Qt renders
// them as anchors and onLinkActivated can route them back into the vault.
// Fenced code blocks are left alone — a wikilink inside one is sample text.
function linkifyWikilinks(text, color) {
  var body = String(text || "")
  var parts = body.split(
    /(```[\s\S]*?```|`[^`\n]*`|\[[^\]]*\]\([^)]*\)|<a[\s\S]*?<\/a>)/)
  for (var i = 0; i < parts.length; i++) {
    if (i % 2 === 1) continue
    parts[i] = parts[i].replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g,
      function(match, target, alias) {
        var name = target.trim()
        var label = (alias || target).trim()
        if (!color) return "[" + label + "](vault://" + encodeURIComponent(name) + ")"
        // Qt ignores Text.linkColor for MarkdownText, so the colour has to
        // ride along inside the anchor itself.
        return "<a href=\"vault://" + encodeURIComponent(name)
          + "\" style=\"color:" + color + ";\">" + label + "</a>"
      })
    // Bare URLs are autolinked by Qt with its own blue; colour them here so
    // every link in the note reads as one.
    if (color) {
      parts[i] = parts[i].replace(/(^|[\s(])(https?:\/\/[^\s<>)\]]+)/g,
        function(match, lead, url) {
          return lead + "<a href=\"" + url + "\" style=\"color:" + color
            + ";\">" + url + "</a>"
        })
    }
  }
  return parts.join("")
}

function wikilinkTarget(url) {
  var link = String(url || "")
  if (link.slice(0, 8) !== "vault://") return ""
  try { return decodeURIComponent(link.slice(8)) } catch (e) { return link.slice(8) }
}

// Resolve a wikilink name against the note index. Exact title first, then a
// case-insensitive match, so `[[carreira]]` still finds `Carreira`.
function resolveNote(name, notes) {
  var wanted = String(name || "").trim()
  if (wanted === "" || !notes) return ""
  var lower = wanted.toLowerCase()
  var fallback = ""
  for (var i = 0; i < notes.length; i++) {
    var title = notes[i].title
    if (title === wanted) return notes[i].path
    if (!fallback && String(title).toLowerCase() === lower) fallback = notes[i].path
  }
  return fallback
}

// ------------------------------------------------------------- new notes

// A typed name becomes a path inside the vault. Slashes are kept so
// `Pessoal/Ideias` creates the folder, but the components are cleaned of the
// characters that make a file awkward to open from a shell.
function newNotePath(vaultPath, name) {
  var raw = String(name || "").trim().replace(/\.md$/i, "")
  var parts = []
  var chunks = raw.split("/")
  for (var i = 0; i < chunks.length; i++) {
    var part = chunks[i].trim()
      .replace(/[\\:*?"<>|]/g, "")
      .replace(/\s+/g, " ")
    if (part !== "" && part !== "." && part !== "..") parts.push(part)
  }
  if (parts.length === 0) return ""
  return String(vaultPath || "").trim().replace(/\/+$/, "") + "/" + parts.join("/") + ".md"
}

function noteTemplate(title) {
  return "# " + String(title || "") + "\n\n"
}

// Mirrors the section headings the vault's own daily notes use, so a day
// created here looks like one created by the Obsidian template.
function dailyTemplate(date) {
  var d = date || new Date()
  var stamp = pad2(d.getDate()) + "-" + pad2(d.getMonth() + 1) + "-" + d.getFullYear()
  return "# " + stamp + "\n\n"
    + "### Main Focus\n\n"
    + "### Tasks: #personal\n\n"
    + "### Tasks: #work\n\n"
    + "### Quick Notes\n\n"
    + "### Day Highlight\n\n"
    + "### Incomplete tasks\n\n"
}
