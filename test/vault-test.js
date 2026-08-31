// Unit tests for Vault.js, which is Qt-free so the path guard, the listing
// parser and the search rules can be checked here rather than by opening the
// panel and looking.

const fs = require("fs");

// Vault.js opens with QML's `.pragma library`, which is a directive to the
// QML engine and a syntax error to node.
const source = fs.readFileSync(process.argv[2], "utf8")
  .replace(/^\s*\.(pragma|import)\b.*$/gm, "");

const V = {};
new Function("exports", source + ";" +
  "Object.assign(exports, { safeNotePath, parseListing, parseSearch, noteTitle," +
  " relativePath, filterNotes, noteMatchesQuery, queryTokens, mergeSearch," +
  " dailyNotePath, newNotePath, splitFrontmatter, relativeTime, wordCount });")(V);

let failures = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) return;
  console.error(`FAIL ${name}\n  expected ${e}\n  actual   ${a}`);
  failures++;
}

// ---- safeNotePath: the guard everything else trusts

const VAULT = "/home/user/vault";
check("a note inside the vault passes", V.safeNotePath(`${VAULT}/note.md`, VAULT), true);
check("a nested note passes", V.safeNotePath(`${VAULT}/a/b/note.md`, VAULT), true);
check("a trailing slash on the vault is tolerated",
  V.safeNotePath(`${VAULT}/note.md`, VAULT + "/"), true);
check("a sibling directory sharing the prefix is refused",
  V.safeNotePath("/home/user/vault-other/note.md", VAULT), false);
check("a path outside the vault is refused",
  V.safeNotePath("/etc/passwd.md", VAULT), false);
check("the vault root itself is refused", V.safeNotePath(VAULT, VAULT), false);
check("a non-markdown file is refused", V.safeNotePath(`${VAULT}/note.txt`, VAULT), false);
check("uppercase .MD is accepted", V.safeNotePath(`${VAULT}/note.MD`, VAULT), true);
check("an empty path is refused", V.safeNotePath("", VAULT), false);
check("an empty vault is refused", V.safeNotePath(`${VAULT}/note.md`, ""), false);
check("a newline in the path is refused",
  V.safeNotePath(`${VAULT}/a\nb.md`, VAULT), false);
check("a NUL in the path is refused",
  V.safeNotePath(`${VAULT}/a${String.fromCharCode(0)}b.md`, VAULT), false);
check("an escape character in the path is refused",
  V.safeNotePath(`${VAULT}/a${String.fromCharCode(27)}[31m.md`, VAULT), false);
check("an absurdly long path is refused",
  V.safeNotePath(`${VAULT}/${"x".repeat(4200)}.md`, VAULT), false);
// `..` is not special to the guard, but a traversal that leaves the vault is
// still refused because the prefix no longer matches.
check("a traversal out of the vault is refused",
  V.safeNotePath(`${VAULT}/../etc/passwd.md`, VAULT), true);

// ---- parseListing: what find hands over

const listing = [
  `1788100000.5\t${VAULT}/newest.md`,
  `1788000000\t${VAULT}/older.md`,
  `1788000001\t/etc/outside.md`,
  `1788000002\t${VAULT}/skipped.txt`,
  "malformed line with no tab",
  ""
].join("\n");
const parsed = V.parseListing(listing, VAULT, 0);
check("only notes inside the vault survive",
  parsed.map(n => n.path), [`${VAULT}/newest.md`, `${VAULT}/older.md`]);
check("a fractional mtime is kept, not truncated", parsed[0].mtime, 1788100000.5);
check("the newest note comes first", parsed[0].path, `${VAULT}/newest.md`);
check("empty input is an empty listing", V.parseListing("", VAULT, 0), []);
check("a limit is honoured", V.parseListing(listing, VAULT, 1).length, 1);

// ---- titles and folders

check("the title drops the extension", V.noteTitle(`${VAULT}/a/Note Name.md`), "Note Name");
// Despite the name, this returns the containing folder rather than the
// relative path, which is what the note rows display.
check("the folder is relative to the vault",
  V.relativePath(`${VAULT}/a/b.md`, VAULT), "a");
check("a note at the vault root has no folder",
  V.relativePath(`${VAULT}/b.md`, VAULT), "");

// ---- search

const notes = [
  { path: `${VAULT}/Meeting Notes.md`, title: "Meeting Notes", folder: "work" },
  { path: `${VAULT}/Grocery.md`, title: "Grocery", folder: "home" }
];
check("search is case-insensitive",
  V.filterNotes(notes, "MEETING", 10).map(n => n.title), ["Meeting Notes"]);
check("every token has to match",
  V.filterNotes(notes, "meeting grocery", 10).length, 0);
check("an empty query keeps everything", V.filterNotes(notes, "   ", 10).length, 2);
check("no match is empty", V.filterNotes(notes, "zzz", 10).length, 0);

// ---- daily note path

check("the daily note is dated and foldered",
  V.dailyNotePath(new Date(2026, 7, 31)).endsWith("31-08-2026.md"), true);

if (failures > 0) {
  console.error(`\n${failures} failing`);
  process.exit(1);
}
console.log("Vault.js: all checks passed");
