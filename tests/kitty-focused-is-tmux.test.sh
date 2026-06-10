#!/usr/bin/env bash
# Regression test for bin/kitty-focused-is-tmux.py — the detector that lets
# kitty-paste-router suppress kitty's redundant ctrl+v handler. Exit 0 must
# mean "the focused kitty window is running tmux"; ANY uncertainty must be
# non-zero so the router falls through to the normal paste path.
set -u

HERE="$(cd "$(dirname -- "$0")" && pwd)"
DET="$HERE/../bin/kitty-focused-is-tmux.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$DET" ] || { echo "FATAL: detector not found at $DET"; exit 2; }

pass=0; fail=0
check() { # desc json want_rc
  local got
  printf '%s' "$2" | python3 "$DET"; got=$?
  if [ "$got" = "$3" ]; then echo "ok   - $1"; pass=$((pass+1))
  else echo "FAIL - $1 : want rc=$3 got rc=$got"; fail=$((fail+1)); fi
}

check "focused window foreground is tmux -> in tmux" \
  '[{"tabs":[{"windows":[{"is_focused":true,"foreground_processes":[{"cmdline":["/usr/bin/tmux","attach"]}]}]}]}]' 0
check "focused window foreground is bash -> not tmux" \
  '[{"tabs":[{"windows":[{"is_focused":true,"foreground_processes":[{"cmdline":["/usr/bin/bash"]}]}]}]}]' 1
check "empty input -> not tmux" "" 1
check "garbage input -> not tmux" "not json" 1
check "tmux only in a NON-focused window -> not tmux" \
  '[{"tabs":[{"windows":[{"is_focused":true,"foreground_processes":[{"cmdline":["nvim"]}]},{"is_focused":false,"foreground_processes":[{"cmdline":["tmux"]}]}]}]}]' 1
# Old kitty that ignores --match and omits is_focused: no window is provably
# focused, so even with tmux present we must report "not tmux" (fail-safe:
# the router then lets the paste happen rather than suppressing it).
check "is_focused absent + tmux present -> not tmux (fail-safe)" \
  '[{"tabs":[{"windows":[{"foreground_processes":[{"cmdline":["/usr/bin/tmux","attach"]}]}]}]}]' 1

echo "--- kitty-focused-is-tmux: PASS=$pass FAIL=$fail"
[ "$fail" = "0" ]
