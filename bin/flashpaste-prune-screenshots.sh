#!/usr/bin/env bash
# flashpaste-prune-screenshots — keep the screenshots dir from growing forever.
#
# GNOME saves every PrtScr capture to ~/Pictures/Screenshots/, and flashpaste
# needs the file to exist while it is being pasted (the agent is handed its
# path). After that it is dead weight: thousands of PNGs pile up.
#
# Normally removes screenshots past the age limit outside the newest 20.
# Under disk pressure it may also remove images at least six hours old.
#
# Only files modified after this pruner was first run are ever touched: the
# first run drops a stamp file and exits, so an existing screenshot library is
# left alone (and so is a file copied in later with an old modification time). Set FLASHPASTE_SCREENSHOT_PRUNE_EXISTING=1 to include it.
#
# Usage: flashpaste-prune-screenshots.sh [--dry-run]
set -euo pipefail

DIR="${FLASHPASTE_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}"
KEEP="${FLASHPASTE_SCREENSHOT_KEEP:-20}"
MAX_AGE_HOURS="${FLASHPASTE_SCREENSHOT_MAX_AGE_HOURS:-24}"
MAX_MIB="${FLASHPASTE_SCREENSHOT_MAX_MIB:-256}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/flashpaste"
STAMP="$STATE_DIR/screenshot-prune-since"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ "$KEEP" =~ ^[0-9]{1,8}$ && "$MAX_AGE_HOURS" =~ ^[0-9]{1,8}$ && "$MAX_MIB" =~ ^[0-9]{1,8}$ ]] || {
  echo "flashpaste-prune-screenshots: KEEP, MAX_AGE_HOURS and MAX_MIB must be whole numbers" >&2
  exit 2
}
[[ -d "$DIR" ]] || exit 0

newer_than_stamp=()
if [[ "${FLASHPASTE_SCREENSHOT_PRUNE_EXISTING:-0}" != "1" ]]; then
  if [[ ! -e "$STAMP" ]]; then
    if (( DRY_RUN )); then
      echo "flashpaste-prune-screenshots: uninitialized; existing screenshots would be left alone"
      exit 0
    fi
    mkdir -p "$STATE_DIR"
    : > "$STAMP"
    echo "flashpaste-prune-screenshots: first run — existing screenshots are left alone from now on"
    exit 0
  fi
  newer_than_stamp=(-newer "$STAMP")
fi

# Newest first; only regular image files directly in the dir (no recursion).
# The daemon's compressed siblings (<name>.fpc.<ext>) are not screenshots of
# their own: they must not use up the keep quota, and go with their original.
mapfile -d '' -t files < <(
  find "$DIR" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
    -not -name '*.fpc.*' \
    "${newer_than_stamp[@]}" -printf '%T@\t%p\0' | sort -z -rn | cut -z -f2-
)

now="$(date +%s)"
keep=$((10#$KEEP))
max_age=$((10#$MAX_AGE_HOURS * 3600))
max_blocks=$((10#$MAX_MIB * 2048)) # stat reports 512-byte allocated blocks
total_blocks=0
declare -a mtimes blocks
removed=0
for i in "${!files[@]}"; do
  f=${files[i]}
  meta=$(stat -c '%Y %b' -- "$f" 2>/dev/null) || continue
  mtimes[i]=${meta% *}
  blocks[i]=${meta##* }
  for sibling in "$f".fpc.*; do
    [[ -f "$sibling" && ! -L "$sibling" ]] || continue
    sibling_blocks=$(stat -c %b -- "$sibling" 2>/dev/null) || continue
    blocks[i]=$((blocks[i] + sibling_blocks))
  done
  total_blocks=$((total_blocks + blocks[i]))
done

# Start with the oldest group so pressure does not evict newer files unnecessarily.
for ((i=${#files[@]}-1; i>=keep; i--)); do
  [[ -v 'mtimes[i]' ]] || continue
  f=${files[i]}
  age=$((now - mtimes[i]))
  if (( age < max_age )); then
    (( max_blocks > 0 && total_blocks > max_blocks && age >= 6 * 3600 )) || continue
  fi
  if (( DRY_RUN )); then
    echo "would remove: $f"
  else
    [[ "$(stat -c %Y -- "$f" 2>/dev/null)" == "${mtimes[i]}" ]] || continue
    rm -f -- "$f" "$f".fpc.*
  fi
  total_blocks=$((total_blocks - blocks[i]))
  removed=$((removed + 1))
done

if (( max_blocks > 0 && total_blocks > max_blocks )); then
  printf 'flashpaste-prune-screenshots: %d MiB remains above the %d MiB target; protected recent images kept\n' \
    "$(((total_blocks + 2047) / 2048))" "$((10#$MAX_MIB))"
fi

# Siblings whose original is gone (deleted by hand, or by an earlier version).
if (( ! DRY_RUN )); then
  while IFS= read -r -d '' sibling; do
    [[ -e "${sibling%.fpc.*}" ]] || rm -f -- "$sibling"
  done < <(find "$DIR" -maxdepth 1 -type f -name '*.fpc.*' "${newer_than_stamp[@]}" -print0)
fi

if (( DRY_RUN )); then
  echo "flashpaste-prune-screenshots: would remove ${removed} of ${#files[@]} screenshot(s)"
else
  echo "flashpaste-prune-screenshots: removed ${removed} of ${#files[@]} screenshot(s)"
fi
