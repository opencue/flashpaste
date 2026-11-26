#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
probe="$repo/bin/flashpaste-paste-codex-image.sh"
tmp=$(mktemp -d)
ref_dir="/tmp/flashpaste-codex-$$"
mkdir -m 700 "$ref_dir"
trap 'rm -rf "$tmp" "$ref_dir"' EXIT
token="$$-42"
ref="$ref_dir/ref-$token"

cat >"$tmp/wl-paste" <<'END'
#!/bin/sh
case "$*" in
  "--list-types")
    [ "${WL_SLOW:-0}" = 0 ] || sleep 1
    printf '%s\n' "${WL_TYPES:-}"
    ;;
  "-t image/png") write_png "${WL_BYTES:-32}" ;;
  *) exit 2 ;;
esac
END
cat >"$tmp/xclip" <<'END'
#!/bin/sh
case "$*" in
  "-selection clipboard -t TARGETS -o") printf '%s\n' "${X_TYPES:-}" ;;
  "-selection clipboard -t image/png -o") write_png "${X_BYTES:-32}" ;;
  *) exit 2 ;;
esac
END
for clipboard in "$tmp/wl-paste" "$tmp/xclip"; do
    sed -i '2i . "$TEST_TMP/png-fixture"' "$clipboard"
done
cat >"$tmp/png-fixture" <<'END'
write_png() {
    if [ "$1" -ge 32 ]; then
        printf '\211PNG\015\012\032\012\000\000\000\015IHDR'
        head -c "$(($1 - 28))" /dev/zero
        printf '\000\000\000\000IEND\256\102\140\202'
    elif [ "$1" -gt 0 ]; then
        printf 'not a PNG'
    fi
}
END
chmod +x "$tmp/"*
export PATH="$tmp:$PATH" FLASHPASTE_REAL_WL_PASTE="$tmp/wl-paste"
export FLASHPASTE_PROC_ROOT="$tmp/proc" TEST_TMP="$tmp" XDG_CACHE_HOME="$tmp/cache"
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
    rm -f "$ref"
    env "$@" "$probe" on 0 100 "$token" || got=$?
    [[ $got = "$want" ]] || { echo "expected $want, got $got: $*" >&2; exit 1; }
    if [[ $want = 0 ]]; then
        [[ -f $(staged_path) ]] || exit 1
    else
        [[ ! -e $ref ]] || exit 1
    fi
}

staged_path() {
    local value
    value=$(cat "$ref")
    printf '%s' "${value:1:-1}"
}

export WL_BYTES=48 X_BYTES=48
assert_probe 0 DISPLAY=:1 X_TYPES=image/png
assert_probe 0 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png
assert_probe 0 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=image/png
assert_probe 0 DISPLAY=:1 X_TYPES=$'TARGETS\nimage/png\ntext/html'
assert_probe 0 WAYLAND_DISPLAY=wayland-0 WL_TYPES=$'image/png\ntext/html;charset=utf-8'
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=$'image/png\ntext/html\ntext/plain;charset=utf-8'
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=$'image/png\ntext/html\ntext/uri-list'
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=text/html
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=$'image/png\ntext/html-other'
# A stale XWayland image must never override authoritative Wayland text,
# a silent clipboard, or a timed-out clipboard owner.
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=text/plain
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png
assert_probe 1 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=image/png WL_TYPES=image/png WL_SLOW=1
assert_probe 0 DISPLAY=:1 WAYLAND_DISPLAY=wayland-0 X_TYPES=UTF8_STRING WL_TYPES=image/png
assert_probe 1 DISPLAY=:1 X_TYPES=$'image/png\nUTF8_STRING'
assert_probe 1 DISPLAY=:1 X_TYPES=image/png-not-a-real-type
assert_probe 0 DISPLAY=:1 X_TYPES=image/png X_BYTES=3147775
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png WL_BYTES=0
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png WL_BYTES=15
assert_probe 1 WAYLAND_DISPLAY=wayland-0 WL_TYPES=image/png WL_BYTES=16777217
! env DISPLAY=:1 X_TYPES=image/png "$probe" off 0 100 "$token" || exit 1
! env DISPLAY=:1 X_TYPES=image/png "$probe" on 1 100 "$token" || exit 1

cache="$XDG_CACHE_HOME/flashpaste/codex-attachments"
assert_probe 0 DISPLAY=:1 X_TYPES=image/png
first=$(staged_path)
assert_probe 0 DISPLAY=:1 X_TYPES=image/png
second=$(staged_path)
[[ $first != "$second" && -f $first && -f $second ]]
touch -d '2 days ago' "$first"
truncate -s 125829120 "$cache/image.AAAAAAAA.png"
assert_probe 0 DISPLAY=:1 X_TYPES=image/png
[[ -f $first && -f $second ]]
truncate -s 134217728 "$cache/image.AAAAAAAA.png"
touch -d '2 days ago' "$cache/image.AAAAAAAA.png"
assert_probe 0 DISPLAY=:1 X_TYPES=image/png
[[ ! -f $first && -f $second ]]
truncate -s 134217728 "$cache/image.AAAAAAAA.png"
assert_probe 1 DISPLAY=:1 X_TYPES=image/png
[[ -f $second ]]
rm "$cache/image.AAAAAAAA.png"

printf '790 (codex) S 789 790 100 42 789 0\n' >"$FLASHPASTE_PROC_ROOT/790/stat"
assert_probe 1 DISPLAY=:1 X_TYPES=image/png
echo 'Native image eligibility: PASS'
