#!/usr/bin/env bash
# flashpaste keybinding drift check — read-only.
#
# Verifies the live kitty.conf and tmux.conf bind Ctrl+V the way the canonical
# source (config/keybindings.canonical) says they must. The double-paste bug
# was these two drifting apart; this catches the drift instead of silently
# pasting twice. Read-only: it never edits your dotfiles.
#
# Env overrides (for testing): KITTY_CONF, TMUX_CONF, CANONICAL.
# Exit 0 = consistent, 1 = drift/missing, 2 = canonical unreadable.
set -u

ROOT="$(cd "$(dirname -- "$0")/.." && pwd)"
CANONICAL="${CANONICAL:-$ROOT/config/keybindings.canonical}"
KITTY_CONF="${KITTY_CONF:-$HOME/.config/kitty/kitty.conf}"
TMUX_CONF="${TMUX_CONF:-$HOME/.tmux.conf}"

[ -r "$CANONICAL" ] || { echo "FATAL: canonical not readable: $CANONICAL"; exit 2; }

drift=0
while read -r surface key want; do
  case "$surface" in ""|\#*) continue ;; esac
  # Escape ERE metacharacters in the key (e.g. the '+' in ctrl+v).
  key_re=$(printf '%s' "$key" | sed 's/[][\\.^$*+?(){}|]/\\&/g')
  case "$surface" in
    kitty) conf="$KITTY_CONF"; line=$(grep -E "^[[:space:]]*map[[:space:]]+$key_re[[:space:]]" "$conf" 2>/dev/null | tail -1) ;;
    tmux)  conf="$TMUX_CONF";  line=$(grep -E "^[[:space:]]*bind[[:space:]]+-n[[:space:]]+$key_re[[:space:]]" "$conf" 2>/dev/null | tail -1) ;;
    *) echo "  ? unknown surface '$surface' in canonical"; drift=1; continue ;;
  esac
  if [ "$want" = "UNBOUND" ]; then
    if [ -z "$line" ]; then
      echo "  ✓ $surface $key -> unbound (as required)"
    else
      echo "  ✗ $surface $key: must be UNBOUND but a live binding exists"
      echo "      live: $line"
      drift=1
    fi
    continue
  fi
  if [ -z "$line" ]; then
    echo "  ✗ $surface $key: no binding found in $conf"
    drift=1
  elif printf '%s' "$line" | grep -Fq -- "$want"; then
    echo "  ✓ $surface $key -> $want"
  else
    echo "  ✗ $surface $key: binding does not route through '$want'"
    echo "      live: $line"
    drift=1
  fi
done < "$CANONICAL"

if [ "$drift" = "0" ]; then
  echo "keybindings: consistent with canonical source"
else
  echo "keybindings: DRIFT detected — fix the live config(s) above"
fi
exit "$drift"
