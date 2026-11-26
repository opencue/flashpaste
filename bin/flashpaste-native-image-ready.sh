#!/usr/bin/env bash
# Only approve a small PNG already offered by the native clipboard. Do not
# claim a selection, create a file, or call back into tmux.
set -euo pipefail

[[ ${1:-} == on && ${2:-} == 0 && ${3:-} =~ ^[1-9][0-9]*$ ]] || exit 1

# The pane's current command can be "node" when Codex was launched through
# npm or a task wrapper. Require Codex in the tty's foreground process group,
# so a background agent in a shell or a Codex instance in another pane is
# not enough to bypass the normal dispatcher.
# Reading only the foreground group's process tree avoids a machine-wide
# proc scan (ps -t) on memory-constrained or heavily loaded hosts.
read_stat() {
    IFS= read -r stat 2>/dev/null <"$proc/$1/stat" || return 1
    # comm is parenthesized and may itself contain spaces or parentheses.
    read -r _ _ group _ tty foreground _ <<<"${stat##*) }"
}

foreground_codex() {
    local proc=${FLASHPASTE_PROC_ROOT:-/proc} stat group tty foreground
    local pid=$1 target_group target_tty i child
    local -a queue children
    read_stat "$pid" || return 1
    [[ $tty != 0 && $foreground =~ ^[1-9][0-9]*$ ]] || return 1
    target_group=$foreground target_tty=$tty
    queue=("$target_group")
    for ((i=0; i<${#queue[@]} && i<32; i++)); do
        pid=${queue[i]}
        read_stat "$pid" || continue
        [[ $tty == "$target_tty" && $group == "$target_group" && $foreground == "$target_group" ]] || continue
        if [[ $stat == "$pid (codex) "* ]]; then
            return 0
        fi
        children=()
        read -ra children 2>/dev/null <"$proc/$pid/task/$pid/children" || :
        for child in "${children[@]}"; do
            [[ $child =~ ^[1-9][0-9]*$ ]] || continue
            queue+=("$child")
            (( ${#queue[@]} < 32 )) || break
        done
    done
    return 1
}

foreground_codex "$3" || exit 1

png_only() {
    # When text also exists, leave text-vs-image precedence to the regular
    # dispatcher. Match full MIME lines, not arbitrary substrings.
    printf '%s\n' "$1" | grep -Fxq 'image/png' &&
        ! printf '%s\n' "$1" | grep -Eq '^(text/|UTF8_STRING$|STRING$|COMPOUND_TEXT$)'
}

small_png() {
    # Large INCR transfers on X11 can fail in Codex's native reader. Keep the
    # regular dispatcher for large images; the probe never consumes >256 KiB
    # plus one sentinel byte and does not retain the image.
    local bytes
    bytes=$(timeout 0.12s "$@" 2>/dev/null | head -c 262145 | wc -c) || return 1
    (( bytes > 0 && bytes <= 262144 ))
}

if [ -n "${WAYLAND_DISPLAY:-}${WAYLAND_SOCKET:-}" ]; then
    # Bypass the wl-paste shim: its fallback may report stale XWayland
    # formats even when the current Wayland offer is text or unavailable.
    types=$(timeout 0.10s "${FLASHPASTE_REAL_WL_PASTE:-/usr/bin/wl-paste}" --list-types 2>/dev/null) || exit 1
    png_only "$types" || exit 1
    small_png "${FLASHPASTE_REAL_WL_PASTE:-/usr/bin/wl-paste}" -t image/png || exit 1
elif [ -z "${DISPLAY:-}" ]; then
    exit 1
fi

if [ -n "${DISPLAY:-}" ]; then
    types=$(timeout 0.10s xclip -selection clipboard -t TARGETS -o 2>/dev/null) || exit 1
    png_only "$types" || exit 1
    small_png xclip -selection clipboard -t image/png -o || exit 1
fi
