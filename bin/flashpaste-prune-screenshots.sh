#!/usr/bin/env bash
# flashpaste-prune-screenshots — keep the screenshots dir from growing forever.
#
# GNOME saves every PrtScr capture to ~/Pictures/Screenshots/, and flashpaste
# needs the file to exist while it is being pasted (the agent is handed its
# path). After that it is dead weight: thousands of PNGs pile up.
#
# This removes screenshots that are BOTH older than FLASHPASTE_SCREENSHOT_MAX_AGE_HOURS
# (default 24) AND not among the newest FLASHPASTE_SCREENSHOT_KEEP (default 20).
#
# Only files that appeared after this pruner was first run are ever touched: the
# first run drops a stamp file and exits, so an existing screenshot library is
# left alone. Set FLASHPASTE_SCREENSHOT_PRUNE_EXISTING=1 to include it.
#
# Usage: flashpaste-prune-screenshots.sh [--dry-run]
set -euo pipefail

DIR="${FLASHPASTE_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
KEEP="${FLASHPASTE_SCREENSHOT_KEEP:-20}"
MAX_AGE_HOURS="${FLASHPASTE_SCREENSHOT_MAX_AGE_HOURS:-24}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/flashpaste"
STAMP="$STATE_DIR/screenshot-prune-since"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ "$KEEP" =~ ^[0-9]+$ && "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || {
  echo "flashpaste-prune-screenshots: KEEP and MAX_AGE_HOURS must be whole numbers" >&2
  exit 2
}
[[ -d "$DIR" ]] || exit 0

newer_than_stamp=()
if [[ "${FLASHPASTE_SCREENSHOT_PRUNE_EXISTING:-0}" != "1" ]]; then
  if [[ ! -e "$STAMP" ]]; then
    mkdir -p "$STATE_DIR"
    : > "$STAMP"
    echo "flashpaste-prune-screenshots: first run — existing screenshots are left alone from now on"
    exit 0
  fi
  newer_than_stamp=(-newer "$STAMP")
fi

# Newest first; only regular image files directly in the dir (no recursion).
mapfile -d '' -t files < <(
  find "$DIR" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
    "${newer_than_stamp[@]}" -printf '%T@\t%p\0' | sort -z -rn | cut -z -f2-
)

now="$(date +%s)"
max_age=$((MAX_AGE_HOURS * 3600))
removed=0
index=0
for f in "${files[@]}"; do
  index=$((index + 1))
  (( index <= KEEP )) && continue
  mtime="$(stat -c %Y -- "$f" 2>/dev/null || echo "$now")"
  (( now - mtime < max_age )) && continue
  if (( DRY_RUN )); then
    echo "would remove: $f"
  else
    rm -f -- "$f"
  fi
  removed=$((removed + 1))
done

if (( DRY_RUN )); then
  echo "flashpaste-prune-screenshots: would remove ${removed} of ${#files[@]} screenshot(s)"
else
  echo "flashpaste-prune-screenshots: removed ${removed} of ${#files[@]} screenshot(s)"
fi
