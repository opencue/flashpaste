#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# kitty ctrl+v router — eliminate the dual-handler double-paste at source.
#
# Problem: a single Ctrl+V inside kitty+tmux fires TWO handlers that both
# call flashpaste-trigger for the same pane — kitty's `map ctrl+v` AND
# tmux's `bind -n C-v`. They land hundreds of ms apart, so the daemon's
# (pane, content) dedup window has to race them. This router removes the
# redundant kitty fire entirely: if the FOCUSED kitty window is running
# tmux, tmux's own bind already handles the paste, so kitty does nothing.
#
# Safety: this is a BELT on top of the daemon's dedup SUSPENDERS. We only
# short-circuit when we can CONFIDENTLY detect tmux in the focused window
# (kitty remote control works AND its foreground process is tmux). On any
# uncertainty — remote control off, kitten missing, parse failure — we fall
# through to the original path, and the daemon's dedup still absorbs the
# duplicate. So a detection miss degrades to today's behaviour, never to a
# broken paste.
#
# Latency: the kitten round-trip (~30ms) only delays kitty's REDUNDANT
# handler. The user-visible paste already happened via tmux's fast bind, so
# this adds zero latency to the actual paste. When NOT in tmux, kitty's
# handler is the only one and ~30ms there is unnoticeable.
# ─────────────────────────────────────────────────────────────────────
set -u

PASTE_IMAGE_FALLBACK="${FLASHPASTE_IMAGE_FALLBACK:-/home/deadpool/paste_image.sh}"
# Resolve kitty's remote-control socket.
#
# kitty appends "-<pid>" to the `listen_on` path, so `listen_on
# unix:.../kitty-main` actually opens `.../kitty-main-<pid>`. Crucially,
# KITTY_LISTEN_ON is NOT in the env this script inherits: kitty's `map
# ctrl+v launch --copy-env` copies kitty's OWN process env, which does not
# carry KITTY_LISTEN_ON (only child windows get it). So the old bare
# `kitty-main` fallback never matched the real `kitty-main-<pid>` socket —
# `kitten @ ls` failed every time, focused_window_is_tmux() always returned
# false, and this router NEVER suppressed kitty's redundant fire. Net effect:
# a single Ctrl+V pasted twice (tmux's bind immediately + this router ~1s
# later). Resolve robustly: trust KITTY_LISTEN_ON when present, else glob the
# real socket (newest wins if several kitty instances are running).
resolve_kitty_sock() {
  if [ -n "${KITTY_LISTEN_ON:-}" ]; then
    printf '%s\n' "$KITTY_LISTEN_ON"
    return 0
  fi
  local base s
  base="/run/user/$(id -u)/kitty-main"
  # Newest matching socket first; `kitty-main-<pid>` is what kitty creates.
  for s in $(ls -1t "$base"-* "$base" 2>/dev/null); do
    [ -S "$s" ] && { printf 'unix:%s\n' "$s"; return 0; }
  done
  # Last-ditch: hand back the bare path; kitten will fail and we fall through
  # to the normal paste path (the daemon's dedup is the remaining safety net).
  printf 'unix:%s\n' "$base"
}
KITTY_SOCK="$(resolve_kitty_sock)"

# Confidently true (exit 0) ONLY when the focused kitty window's foreground
# process is tmux. Any failure to determine that returns non-zero, so the
# caller falls through to the normal paste path.
focused_window_is_tmux() {
  command -v kitten >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  kitten @ --to "$KITTY_SOCK" ls --match state:focused 2>/dev/null \
    | python3 "$(dirname -- "$0")/kitty-focused-is-tmux.py" 2>/dev/null
}

if focused_window_is_tmux; then
  # tmux's `bind -n C-v` owns this paste. Do nothing.
  exit 0
fi

# Not in tmux (or undetectable) — run the original kitty paste path. The
# daemon dedups if this turns out to be a duplicate of tmux's fire.
pane="$(tmux display-message -p "#{pane_id}" 2>/dev/null)"
# Only call the daemon trigger when we actually have a pane id. An empty
# pane (no tmux at all) can't be a paste target, so go straight to the
# image fallback instead of handing the daemon a blank pane.
if [ -n "$pane" ] && flashpaste-trigger "$pane" 2>/dev/null; then
  exit 0
fi
exec "$PASTE_IMAGE_FALLBACK"
