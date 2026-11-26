#!/usr/bin/env bash
# Paste an immutable PNG path so Codex does not re-read the clipboard or
# decode and re-encode the full image on the interactive hot path.
set -euo pipefail

[[ ${1:-} == on && ${2:-} == 0 && ${3:-} =~ ^[1-9][0-9]*$ ]] || exit 1
[[ ${4:-} =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]] || exit 1
[[ -z ${5:-} || $5 == screenshot ]] || exit 1
client_token=$4

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

native_fallback() {
    # Report only metadata, never clipboard contents, filenames or MIME lists.
    logger -t flashpaste-native -- "client=$client_token backend=$backend phase=$1 status=${2:-1}" 2>/dev/null || :
    exit 1
}

has_pasteable_png() {
    # Browsers can export an HTML representation of the copied image along
    # with the PNG. Never read or insert the HTML. Leave real text, URLs and
    # other text formats to the regular dispatcher.
    local type found=1
    while IFS= read -r type; do
        case "$type" in
            image/png) found=0 ;;
            text/html|text/html\;*) ;;
            text/*|UTF8_STRING|STRING|TEXT|COMPOUND_TEXT) return 1 ;;
        esac
    done <<<"$1"
    return "$found"
}

if [[ ${5:-} == screenshot ]]; then
    # This explicit menu action selects a saved screenshot, not the clipboard.
    # Don't open a Wayland surface or fall back to another clipboard path.
    backend=screenshot
    shots=${FLASHPASTE_SCREENSHOTS_DIR:-$HOME/Pictures/Screenshots}
    [[ $shots == /* ]] || exit 1
    IFS= read -r -d '' entry < <(
        find "$shots" -maxdepth 1 -type f -iname '*.png' ! -iname 'flashpaste-clip-*.png' \
            -newermt '60 seconds ago' ! -newermt now -printf '%T@ %p\0' 2>/dev/null |
            sort -znr
    ) || exit 1
    source=${entry#* }
    [[ -f $source && ! -L $source && -O $source ]] || exit 1
    read_png=(cat -- "$source")
    read_timeout=0.30s
elif [ -n "${WAYLAND_DISPLAY:-}${WAYLAND_SOCKET:-}" ]; then
    # Bypass the wl-paste shim: its fallback may report stale XWayland
    # formats even when the current Wayland offer is text or unavailable.
    wl=${FLASHPASTE_REAL_WL_PASTE:-/usr/bin/wl-paste}
    backend=wayland
    probe_types=("$wl" --list-types)
    read_png=("$wl" -t image/png)
    # A confirmed image can arrive late from a GNOME screenshot or a busy
    # owner. Avoid falling into the slower clipboard round-trip at 300 ms.
    read_timeout=0.65s
elif [ -n "${DISPLAY:-}" ]; then
    backend=x11
    probe_types=(xclip -selection clipboard -t TARGETS -o)
    read_png=(xclip -selection clipboard -t image/png -o)
    read_timeout=0.30s
else
    exit 1
fi
if [[ $backend != screenshot ]]; then
    types=$(timeout -k 0.05s 0.10s "${probe_types[@]}" 2>/dev/null) || {
        status=$?
        case $status in 124|137) native_fallback probe-types "$status" ;; esac
        exit 1 # e.g. no clipboard selection; normal, don't log every text paste
    }
    has_pasteable_png "$types" || exit 1
fi

umask 077
dir=${XDG_CACHE_HOME:-$HOME/.cache}/flashpaste/codex-attachments
[[ $dir == /* && $dir != *[[:cntrl:]]* ]] || native_fallback cache-path
[[ -d $dir ]] || mkdir -p -- "$dir" || native_fallback cache-directory "$?"
[[ ! -L $dir && -O $dir ]] || native_fallback cache-owner
exec 9>"$dir/.lock" || native_fallback cache-lock-open "$?"
flock -n 9 || native_fallback cache-busy "$?"
image=$(mktemp --suffix=.png "$dir/image.XXXXXXXX") || native_fallback cache-create "$?"
trap 'rm -f -- "$image"' EXIT
# Write straight to the attachment instead of relaying the PNG through a pipe.
# Leave one extra KiB so even a truncated oversized write fails the size check.
{
    (
        set +o posix # Bash uses 1 KiB units for ulimit -f outside POSIX mode.
        limit=$(ulimit -Sf)
        if [[ $limit == unlimited || $limit -gt 16385 ]]; then
            ulimit -Sf 16385 || exit 1
        fi
        ulimit -Sc 0 || exit 1
        exec timeout -k 0.05s "$read_timeout" "${read_png[@]}"
    ) >"$image"
} 2>/dev/null || native_fallback read-png "$?"
size=$(wc -c <"$image") || native_fallback png-size "$?"
(( size >= 45 && size <= 16777216 )) || native_fallback png-size
header=$(od -An -tx1 -N16 "$image") || native_fallback png-header "$?"
[[ ${header//[[:space:]]/} == 89504e470d0a1a0a0000000d49484452 ]] || native_fallback png-header
end=$(od -An -tx1 -j "$((size - 12))" -N12 -- "$image") || native_fallback png-footer "$?"
[[ ${end//[[:space:]]/} == 0000000049454e44ae426082 ]] || native_fallback png-footer
# Reclaim old files only when needed for space. Never evict a recent draft
# attachment; if the cache is still full, fall back to the dispatcher.
cache_has_space() {
    local usage
    usage=$(du -sb -- "$dir") || return 1
    (( ${usage%%[[:space:]]*} <= 134217728 ))
}
if ! cache_has_space; then
    find "$dir" -maxdepth 1 -type f -name 'image.????????.png' -mmin +1440 -delete || native_fallback cache-prune "$?"
    cache_has_space || native_fallback cache-full
fi
foreground_codex "$3" || native_fallback pane-changed

# The synchronous tmux menu queue reads this client's reference before
# processing another action from the same client. The reference names
# an immutable attachment; concurrent clients use separate slots.
refs=/tmp/flashpaste-codex-${client_token%-*}
[[ -d $refs ]] || mkdir -m 700 -- "$refs" 2>/dev/null || [[ -d $refs ]] || native_fallback reference-directory
[[ ! -L $refs && -O $refs && $(stat -c '%a' -- "$refs") == 700 ]] || native_fallback reference-owner
reference=$refs/ref-$client_token
if [[ ! -e $reference ]]; then
    shopt -s nullglob
    slots=("$refs"/ref-*)
    if (( ${#slots[@]} >= 256 )); then
        find "$refs" -maxdepth 1 -type f -name 'ref-*' -mmin +1440 -delete || native_fallback reference-prune "$?"
        slots=("$refs"/ref-*)
        (( ${#slots[@]} < 256 )) || native_fallback reference-full
    fi
fi
trap 'rm -f -- "$image" "$reference"' EXIT
quoted=${image//\'/\'\\\'\'}
printf "'%s'" "$quoted" >"$reference" || native_fallback reference-write "$?"
trap - EXIT
