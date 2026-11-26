#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# WORKING VERSION: v1.0 — 2026-05-19
#
# Bound from kitty.conf as:
#   map ctrl+v       launch --type=background --copy-env -- ~/paste_image.sh
#   map ctrl+alt+v   launch --type=background --copy-env -- ~/paste_image.sh image
#
# Companion files (all v1.0, edit them together):
#   - ~/.local/bin/wl-paste                (xclip-fallback shim)
#   - ~/.local/bin/tmux-paste-dispatch.sh  (tmux right-click handler)
#
# Image branch sends a raw Ctrl-V byte via `kitty @ send-text`; Claude
# Code's TUI catches it and reads the image via the wl-paste shim. Do
# NOT replace this with the file-save + @-mention approach again — that
# was tried and failed because Claude Code's TUI doesn't auto-attach
# typed paths.
#
# Edit log:
#   2026-05-19  reverted from xclip→wl-copy bridge (mutter rejected
#               surfaceless wl-copy clipboard claims) back to raw
#               Ctrl-V byte via kitty send-text. The wl-paste shim now
#               handles the image read transparently.
# ─────────────────────────────────────────────────────────────────────
# Smart paste for kitty + tmux. Bound from kitty.conf as:
#   map ctrl+v       launch --type=background --copy-env -- ~/paste_image.sh
#   map ctrl+alt+v   launch --type=background --copy-env -- ~/paste_image.sh image
#
# Modes:
#   no arg    → AUTO: routes to image branch if clipboard has image,
#               otherwise to text branch. The user just presses Ctrl+V
#               and the right thing happens for both text AND images.
#   "image"   → force image branch (manual override; useful when xclip
#               disagrees with wl-paste about whether image is present)
#   "text"    → force text branch
set -u

_self_dir=$(dirname -- "$0")
_clog_helper=$(command -v clip-pipeline-log.sh 2>/dev/null || true)
[ -n "$_clog_helper" ] || _clog_helper="$_self_dir/clip-pipeline-log.sh"
. "$_clog_helper" 2>/dev/null || true
type clog >/dev/null 2>&1 || clog() { :; }
clog "paste-image" "event=invoked" "arg='${1:-}'" "KITTY_WINDOW_ID='${KITTY_WINDOW_ID:-}'" "KITTY_LISTEN_ON='${KITTY_LISTEN_ON:-}'"

# Find the live kitty socket
sock="${KITTY_LISTEN_ON:-}"
if [ -z "$sock" ] || [ ! -S "${sock#unix:}" ]; then
  for s in /run/user/$(id -u)/kitty-main-*; do
    [ -S "$s" ] && sock="unix:$s" && break
  done
fi
if [ -z "$sock" ]; then
  clog "paste-image" "event=error" "reason=no-kitty-socket"
  exit 1
fi
clog "paste-image" "event=socket-resolved" "sock='$sock'"

# Route by intent.
#   arg "image"  → force image branch (Ctrl+Alt+V binding, manual override)
#   arg "text"   → force text branch
#   no arg       → AUTO: image if clipboard has image, else text. This
#                  makes Ctrl+V in kitty behave like the user expects:
#                  paste whatever's on the clipboard, image or text.
mode="${1:-auto}"
if [ "$mode" = "auto" ] || [ "$mode" = "image" ]; then
  capture_helper=$(command -v flashpaste-capture-clip 2>/dev/null)
  if [ -z "$capture_helper" ] && [ -x "$_self_dir/flashpaste-capture-clip" ]; then
    capture_helper="$_self_dir/flashpaste-capture-clip"
  fi
  if [ -n "$capture_helper" ]; then
    # A single probe both chooses the paste mode and stages a browser image
    # for the daemon. Exit 2 means image MIME was offered but staging failed;
    # still send Ctrl-V so the TUI can read the clipboard itself.
    capture_out=$("$capture_helper" 2>/dev/null)
    capture_rc=$?
    clog "paste-image" "event=capture" "rc=$capture_rc" "dest='$capture_out'"
    if [ "$mode" = "auto" ]; then
      case "$capture_rc" in
        0|2) mode=image ;;
        1) mode=text ;;
      esac
    fi
    if [ "$capture_rc" = "0" ]; then
      # Keep the existing inotify/X11 selection handoff window.
      sleep 0.06
    fi
  fi
fi
if [ "$mode" = "auto" ]; then
  # Compatibility for standalone installs without the capture helper.
  # Wayland is authoritative when it answers; don't read any text payload.
  types=$(timeout 0.5 wl-paste --list-types 2>/dev/null) || types=
  if [ -z "$types" ]; then
    types=$(timeout 0.5 xclip -selection clipboard -t TARGETS -o 2>/dev/null) || types=
  fi
  if [[ $'\n'"$types" == *$'\n'image/* ]]; then
    mode=image
    clog "paste-image" "event=auto-route" "decision=image" "reason=clipboard-has-image"
  else
    mode=text
    clog "paste-image" "event=auto-route" "decision=text" "reason=no-image-on-clipboard"
  fi
fi

if [ "$mode" = "image" ]; then
  win="${KITTY_WINDOW_ID:-}"
  match=()
  [ -n "$win" ] && match=(--match "id:$win")
  clog "paste-image" "event=branch-image" "match='${match[*]}'"

  # Send raw Ctrl-V byte to the focused kitty window — Claude Code's TUI
  # catches it and reads the image via `wl-paste -t image/png`. The
  # wl-paste shim at ~/.local/bin/wl-paste transparently falls back to
  # xclip when mutter's surfaceless block leaves the real wl-paste empty,
  # so Claude gets the image bytes regardless of which side owns the
  # selection.
  printf '\026' | kitty @ --to "$sock" send-text "${match[@]}" --stdin
  rc=$?
  clog "paste-image" "event=done" "branch=image" "rc=$rc"
  exit $rc
else
  clog "paste-image" "event=branch-text" "action=paste_from_clipboard"
  kitty @ --to "$sock" action --self paste_from_clipboard
  rc=$?
  clog "paste-image" "event=done" "branch=text" "rc=$rc"
  exit $rc
fi
