#!/usr/bin/env bash
# Paste an immutable PNG path so Codex does not re-read the clipboard or
# decode and re-encode the full image on the interactive hot path.
set -euo pipefail

[[ ${1:-} == on && ${2:-} == 0 && ${3:-} =~ ^[1-9][0-9]*$ ]] || exit 1
[[ ${4:-} =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || exit 1

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
    local type found=1
    while IFS= read -r type; do
        case "$type" in
            image/png) found=0 ;;
            text/*|UTF8_STRING|STRING|COMPOUND_TEXT) return 1 ;;
        esac
    done <<<"$1"
    return "$found"
}

if [ -n "${WAYLAND_DISPLAY:-}${WAYLAND_SOCKET:-}" ]; then
    # Bypass the wl-paste shim: its fallback may report stale XWayland
    # formats even when the current Wayland offer is text or unavailable.
    wl=${FLASHPASTE_REAL_WL_PASTE:-/usr/bin/wl-paste}
    types=$(timeout 0.10s "$wl" --list-types 2>/dev/null) || exit 1
    read_png=("$wl" -t image/png)
elif [ -n "${DISPLAY:-}" ]; then
    types=$(timeout 0.10s xclip -selection clipboard -t TARGETS -o 2>/dev/null) || exit 1
    read_png=(xclip -selection clipboard -t image/png -o)
else
    exit 1
fi
png_only "$types" || exit 1

umask 077
dir=${XDG_CACHE_HOME:-$HOME/.cache}/flashpaste/codex-attachments
[[ $dir == /* && $dir != *[[:cntrl:]]* ]] || exit 1
[[ -d $dir ]] || mkdir -p -- "$dir" || exit 1
[[ ! -L $dir && -O $dir ]] || exit 1
exec 9>"$dir/.lock"
flock -n 9 || exit 1
image=$(mktemp --suffix=.png "$dir/image.XXXXXXXX") || exit 1
trap 'rm -f -- "$image"' EXIT
timeout 0.30s "${read_png[@]}" 2>/dev/null | head -c 16777217 >"$image" || exit 1
size=$(wc -c <"$image")
(( size >= 45 && size <= 16777216 )) || exit 1
header=$(od -An -tx1 -N16 "$image")
[[ ${header//[[:space:]]/} == 89504e470d0a1a0a0000000d49484452 ]] || exit 1
end=$(tail -c 12 -- "$image" | od -An -tx1)
[[ ${end//[[:space:]]/} == 0000000049454e44ae426082 ]] || exit 1
# Reclaim old files only when needed for space. Never evict a recent draft
# attachment; if the cache is still full, fall back to the dispatcher.
cache_has_space() {
    local usage
    usage=$(du -sb -- "$dir") || return 1
    (( ${usage%%[[:space:]]*} <= 134217728 ))
}
if ! cache_has_space; then
    find "$dir" -maxdepth 1 -type f -name 'image.????????.png' -mmin +1440 -delete || exit 1
    cache_has_space || exit 1
fi
foreground_codex "$3" || exit 1

# The synchronous tmux menu queue reads this client's reference before
# processing another action from the same client. The reference names
# an immutable attachment; concurrent clients use separate slots.
refs=/tmp/flashpaste-codex-${4%-*}
[[ -d $refs ]] || mkdir -m 700 -- "$refs" 2>/dev/null || [[ -d $refs ]] || exit 1
[[ ! -L $refs && -O $refs && $(stat -c '%a' -- "$refs") == 700 ]] || exit 1
reference=$refs/ref-$4
if [[ ! -e $reference ]]; then
    find "$refs" -maxdepth 1 -type f -name 'ref-*' -mmin +1440 -delete || exit 1
    shopt -s nullglob
    slots=("$refs"/ref-*)
    (( ${#slots[@]} < 256 )) || exit 1
fi
trap 'rm -f -- "$image" "$reference"' EXIT
quoted=${image//\'/\'\\\'\'}
printf "'%s'" "$quoted" >"$reference"
trap - EXIT
