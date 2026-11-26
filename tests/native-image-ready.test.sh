#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
probe="$repo/bin/flashpaste-native-image-ready.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/wl-paste" <<'END'
#!/bin/sh
case "$*" in
  "--list-types")
    [ "${WL_SLOW:-0}" = 0 ] || sleep 1
    printf '%s\n' "${WL_TYPES:-}"
    ;;
  "-t image/png") head -c "${WL_BYTES:-32}" /dev/zero ;;
  *) exit 2 ;;
esac
END
cat >"$tmp/xclip" <<'END'
#!/bin/sh
case "$*" in
  "-selection clipboard -t TARGETS -o") printf '%s\n' "${X_TYPES:-}" ;;
  "-selection clipboard -t image/png -o") head -c "${X_BYTES:-32}" /dev/zero ;;
  *) exit 2 ;;
esac
END
chmod +x "$tmp/"*
export PATH="$tmp:$PATH" FLASHPASTE_REAL_WL_PASTE="$tmp/wl-paste"
export FLASHPASTE_PROC_ROOT="$tmp/proc"
mkdir -p "$FLASHPASTE_PROC_ROOT"/{100,789/task/789,790}
printf '100 (shell) S 1 100 100 42 789 0\n' >"$FLASHPASTE_PROC_ROOT/100/stat"
printf '789 (node) S 100 789 100 42 789 0\n' >"$FLASHPASTE_PROC_ROOT/789/stat"
# Linux emits a trailing space, not a newline, for /proc/PID/.../children.
printf '790 ' >"$FLASHPASTE_PROC_ROOT/789/task/789/children"
printf '790 (codex) S 789 789 100 42 789 0\n' >"$FLASHPASTE_PROC_ROOT/790/stat"
unset WAYLAND_DISPLAY WAYLAND_SOCKET DISPLAY

assert_probe() {
    local want=$1 got=0
    shift
    env "$@" "$probe" on 0 100 || got=$?
    [[ $got = "$want" ]] || { echo "expected $want, got $got: $*" >&2; exit 1; }
}

assert_probe 0 DISPLAY=:1 X_TYPES=image/png
assert_probe 0 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png
assert_probe 0 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=image/png
# A stale XWayland image must never override authoritative Wayland text,
# a silent clipboard, or a timed-out clipboard owner.
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=text/plain
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=image/png WL_SLOW=1
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=UTF8_STRING WL_TYPES=image/png
assert_probe 1 DISPLAY=:1 X_TYPES=$'image/png\nUTF8_STRING'
assert_probe 1 DISPLAY=:1 X_TYPES=image/png-not-a-real-type
assert_probe 1 DISPLAY=:1 X_TYPES=image/png X_BYTES=3147775
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png WL_BYTES=0
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png WL_BYTES=262145
! env DISPLAY=:1 X_TYPES=image/png "$probe" off 0 100 || exit 1
! env DISPLAY=:1 X_TYPES=image/png "$probe" on 1 100 || exit 1
printf '790 (codex) S 789 790 100 42 789 0\n' >"$FLASHPASTE_PROC_ROOT/790/stat"
assert_probe 1 DISPLAY=:1 X_TYPES=image/png
echo 'Native image eligibility: PASS'
