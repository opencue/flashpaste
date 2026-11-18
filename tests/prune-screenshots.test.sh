#!/usr/bin/env bash
# Behavioral test for bin/flashpaste-prune-screenshots.sh. Works on a private
# temp dir only — it never touches the real ~/Pictures/Screenshots.
set -u

HERE="$(cd "$(dirname -- "$0")" && pwd)"
PRUNE="$HERE/../bin/flashpaste-prune-screenshots.sh"
[ -x "$PRUNE" ] || { echo "FATAL: script not found at $PRUNE"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export FLASHPASTE_SCREENSHOTS_DIR="$T/shots" XDG_STATE_HOME="$T/state"
mkdir -p "$T/shots/sub"

pass=0; fail=0
check() { # <description> <condition…>
  local what="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $what"; fi
}
count() { find "$T/shots" -maxdepth 1 -type f | wc -l; }

# A library that existed before the pruner was installed.
touch -d '40 days ago' "$T/shots/library-1.png" "$T/shots/library-2.png"

# First run: only drops the stamp, removes nothing.
"$PRUNE" >/dev/null
check "first run keeps everything" [ "$(count)" -eq 2 ]
check "first run writes the stamp" [ -e "$T/state/flashpaste/screenshot-prune-since" ]

# Screenshots taken afterwards. The stamp is back-dated so "3 days ago" counts as newer.
touch -d '30 days ago' "$T/state/flashpaste/screenshot-prune-since"
for i in 1 2 3 4 5; do touch -d "$((i + 2)) days ago" "$T/shots/old-$i.png"; done
touch -d '3 days ago' "$T/shots/old-1.png.fpc.webp" "$T/shots/notes.txt" "$T/shots/sub/nested.png"
touch "$T/shots/fresh-1.png" "$T/shots/fresh-2.png"

FLASHPASTE_SCREENSHOT_KEEP=3 "$PRUNE" --dry-run >/dev/null
check "dry run removes nothing" [ "$(count)" -eq 11 ]

FLASHPASTE_SCREENSHOT_KEEP=3 "$PRUNE" >/dev/null
check "fresh screenshots stay" [ -e "$T/shots/fresh-1.png" -a -e "$T/shots/fresh-2.png" ]
check "the newest old one fills the keep quota" [ -e "$T/shots/old-1.png" -o -e "$T/shots/old-1.png.fpc.webp" ]
check "older screenshots are removed" [ ! -e "$T/shots/old-4.png" -a ! -e "$T/shots/old-5.png" ]
check "the pre-existing library is untouched" [ -e "$T/shots/library-1.png" -a -e "$T/shots/library-2.png" ]
check "non-image files are untouched" [ -e "$T/shots/notes.txt" ]
check "subdirectories are untouched" [ -e "$T/shots/sub/nested.png" ]

# Opting in to the existing library.
FLASHPASTE_SCREENSHOT_PRUNE_EXISTING=1 FLASHPASTE_SCREENSHOT_KEEP=2 "$PRUNE" >/dev/null
check "PRUNE_EXISTING removes the old library" [ ! -e "$T/shots/library-1.png" ]
check "PRUNE_EXISTING still keeps fresh files" [ -e "$T/shots/fresh-1.png" -a -e "$T/shots/fresh-2.png" ]

FLASHPASTE_SCREENSHOT_KEEP=abc "$PRUNE" >/dev/null 2>&1
check "a non-numeric setting is rejected" [ $? -eq 2 ]

echo "prune-screenshots: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
