#!/usr/bin/env bash
# Fixture test for bin/flashpaste-keybindings-check.sh. Drives the checker
# against synthetic kitty/tmux configs via the KITTY_CONF/TMUX_CONF/CANONICAL
# env overrides — no dependence on the user's real dotfiles, so it runs in CI.
set -u

HERE="$(cd "$(dirname -- "$0")" && pwd)"
CHECK="$HERE/../bin/flashpaste-keybindings-check.sh"
CANON="$HERE/../config/keybindings.canonical"
[ -x "$CHECK" ] || { echo "FATAL: checker not found"; exit 2; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # desc want_rc actual_rc
  if [ "$2" = "$3" ]; then echo "ok   - $1"; pass=$((pass+1))
  else echo "FAIL - $1 : want rc=$2 got rc=$3"; fail=$((fail+1)); fi
}

# Consistent fixtures: kitty leaves ctrl+v unbound (canonical: UNBOUND since
# 2026-06-10 — XWayland kitty broke the router's tmux detection), tmux binds
# C-v to the trigger.
printf '# ctrl+v intentionally unmapped\nmap ctrl+shift+v paste_from_clipboard\n' > "$T/kitty.ok"
printf 'bind -n C-v run-shell -b "flashpaste-trigger %%pane"\n' > "$T/tmux.ok"
CANONICAL="$CANON" KITTY_CONF="$T/kitty.ok" TMUX_CONF="$T/tmux.ok" bash "$CHECK" >/dev/null 2>&1
check "consistent configs -> rc 0" 0 $?

# Drift: kitty still intercepts ctrl+v (any binding violates UNBOUND).
printf 'map ctrl+v launch -- /x/kitty-paste-router.sh\n' > "$T/kitty.drift"
CANONICAL="$CANON" KITTY_CONF="$T/kitty.drift" TMUX_CONF="$T/tmux.ok" bash "$CHECK" >/dev/null 2>&1
check "kitty ctrl+v bound despite UNBOUND -> rc 1" 1 $?

# Missing tmux binding entirely.
printf '# no C-v here\n' > "$T/tmux.missing"
CANONICAL="$CANON" KITTY_CONF="$T/kitty.ok" TMUX_CONF="$T/tmux.missing" bash "$CHECK" >/dev/null 2>&1
check "missing tmux binding -> rc 1" 1 $?

# The literal '+' in ctrl+v must match literally, not as an ERE quantifier:
# a 'ctrlv' binding must NOT count as a ctrl+v binding, so UNBOUND still
# passes (rc 0) — proving the key regex didn't degrade into 'ctrl.v'.
printf 'map ctrlv launch -- /x/kitty-paste-router.sh\n' > "$T/kitty.plusbug"
CANONICAL="$CANON" KITTY_CONF="$T/kitty.plusbug" TMUX_CONF="$T/tmux.ok" bash "$CHECK" >/dev/null 2>&1
check "literal + : 'ctrlv' binding does not violate ctrl+v UNBOUND -> rc 0" 0 $?

# Positive-substring rules still work: a canonical that REQUIRES the router
# must fail when kitty routes elsewhere, and pass when it matches.
printf 'kitty  ctrl+v  kitty-paste-router.sh\ntmux   C-v     flashpaste-trigger\n' > "$T/canon.positive"
printf 'map ctrl+v launch -- /x/kitty-paste-router.sh\n' > "$T/kitty.router"
CANONICAL="$T/canon.positive" KITTY_CONF="$T/kitty.router" TMUX_CONF="$T/tmux.ok" bash "$CHECK" >/dev/null 2>&1
check "positive rule: router binding matches -> rc 0" 0 $?
printf 'map ctrl+v launch -- sh -c flashpaste-trigger\n' > "$T/kitty.inline"
CANONICAL="$T/canon.positive" KITTY_CONF="$T/kitty.inline" TMUX_CONF="$T/tmux.ok" bash "$CHECK" >/dev/null 2>&1
check "positive rule: non-router binding drifts -> rc 1" 1 $?

echo "--- keybindings-check: PASS=$pass FAIL=$fail"
[ "$fail" = "0" ]
