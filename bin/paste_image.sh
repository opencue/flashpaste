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
if [ "$mode" = "auto" ]; then
  # Wayland is authoritative when it answers. The wl-paste shim may
  # already fall back to X11; probe X11 here only if PATH has a plain
  # wl-paste with no result. Never read clipboard data just to log it.
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
  # Bridge the "browser Copy Image" case (ROADMAP.md:32). The flashpasted
  # daemon's fast path is wired to inotify on ~/Pictures/Screenshots/, so
  # an image copied from a browser (no file written) bypasses staging.
  # Without staging there's nothing for Claude Code's wl-paste shim to
  # fall back to — mutter blocks surfaceless reads of Firefox's Wayland
  # selection, and Firefox under Wayland often doesn't mirror image
  # bytes to the X11 selection either, so Claude gets 0 bytes.
  #
  # The capture helper reads the bytes from THIS context (kitty
  # subprocess, often closer to the focused surface than the daemon's
  # surfaceless connection), validates the magic, and writes them to
  # ~/Pictures/Screenshots/flashpaste-clip-latest.png. The daemon's
  # inotify watcher picks the file up and stages it in RAM, after which
  # the existing X11/Wayland ownership path serves Claude correctly.
  #
  # Cost: one wl-paste + one xclip probe + one mv on every image paste
  # (~30–80ms total). If the helper returns non-zero we proceed anyway
  # — the existing send-text path remains the source of truth and any
  # regression manifests as the old "no image attached" behaviour, not
  # corruption.
  capture_helper=$(command -v flashpaste-capture-clip 2>/dev/null)
  if [ -z "$capture_helper" ] && [ -x "$(dirname "$0")/flashpaste-capture-clip" ]; then
    capture_helper="$(dirname "$0")/flashpaste-capture-clip"
  fi
  if [ -n "$capture_helper" ]; then
    capture_out=$("$capture_helper" 2>/dev/null)
    capture_rc=$?
    clog "paste-image" "event=capture" "rc=$capture_rc" "dest='$capture_out'"
    if [ "$capture_rc" = "0" ]; then
      # Give the daemon's inotify watcher one tick to fire IN_MOVED_TO,
      # read the bytes (~5–20ms for a typical browser image), and notify
      # the X11 owner to refresh. 60ms covers the 95th percentile on
      # this stack; longer would add user-visible latency, shorter
      # races the X11 SetSelectionOwner call.
      sleep 0.06
    fi
  fi

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
