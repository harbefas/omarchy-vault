#!/usr/bin/env bash
# bounded-output caps untrusted output, and its exit status is what tells the
# panel apart an empty vault from one it could not read. Both halves are
# checked here.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
bounded="$root/bin/bounded-output"
failures=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
  local name=$1 expected=$2 actual=$3
  [ "$expected" = "$actual" ] && return
  printf 'FAIL %s\n  expected %s\n  actual   %s\n' "$name" "$expected" "$actual" >&2
  failures=$((failures + 1))
}

mkdir -p "$work/vault"
printf 'note\n' >"$work/vault/a.md"

"$bounded" true
check "a command that succeeds succeeds" '0' "$?"

check "output passes through" 'note' "$("$bounded" cat "$work/vault/a.md")"

"$bounded" find "$work/does-not-exist" >/dev/null 2>&1
check "a failing command fails" '1' "$?"

"$bounded" this-command-does-not-exist >/dev/null 2>&1
check "a missing binary reports 127" '127' "$?"

# The whole point of the wrapper: output past the cap is truncated, and that
# is not a failure even though the writer dies of SIGPIPE.
bytes=$("$bounded" yes hello 2>/dev/null | wc -c)
check "output is capped" '4194305' "$bytes"

"$bounded" yes hello >/dev/null 2>&1
check "hitting the cap is not a failure" '0' "$?"

# rg says 1 when nothing matched, which the service treats as an empty result
# rather than a fault, so the wrapper has to pass it through unchanged.
"$bounded" rg --files-with-matches zzzz "$work/vault" >/dev/null 2>&1
check "rg finding nothing stays 1" '1' "$?"

if [ "$failures" -gt 0 ]; then
  printf '\n%d failing\n' "$failures" >&2
  exit 1
fi
echo "bin/: all checks passed"
