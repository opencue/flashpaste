#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/home"
export PATH="$tmp/bin:$root/bin:$PATH" HOME="$tmp/home"
export FLASHPASTE_REAL_WL_PASTE="$tmp/bin/wl-paste"
export FLASHPASTE_CAPTURE_DIR="$tmp/images" KITTY_LISTEN_ON="unix:$tmp/fake-kitty"
export CALLS="$tmp/calls" PNG="$tmp/clipboard.png"
printf '\211PNG\r\n\032\nfixture' >"$PNG"

cat >"$tmp/bin/wl-paste" <<'SH'
#!/usr/bin/env bash
echo "wl $*" >>"$CALLS"
case "$*" in
  --list-types)
    case "$MODE" in image|bad|fallback) printf 'image/png\n' ;; text) printf 'text/plain\n' ;; esac
    ;;
  '-t image/png')
    case "$MODE" in bad|fallback) printf 'not an image' ;; *) cat "$PNG" ;; esac
    ;;
  *) printf 'diagnostic payload'; sleep "${READ_DELAY:-0}" ;;
esac
SH
cat >"$tmp/bin/xclip" <<'SH'
#!/usr/bin/env bash
echo "x $*" >>"$CALLS"
case "$*" in
  *TARGETS*) printf 'image/png\n' ;;
  *image/png*) if [ "$MODE" = bad ]; then printf 'not an image'; else cat "$PNG"; fi ;;
  *) printf 'diagnostic payload'; sleep "${READ_DELAY:-0}" ;;
esac
SH
cat >"$tmp/bin/kitty" <<'SH'
#!/usr/bin/env bash
echo "kitty $*" >>"$CALLS"
case "$*" in *send-text*) cat >/dev/null ;; esac
SH
chmod +x "$tmp/bin/"*
run() { : >"$CALLS"; MODE="$1" bash "$root/bin/paste_image.sh" "${@:2}"; }
forbidden() {
  if grep -Eq -- "$1" "$CALLS"; then printf 'Unexpected clipboard call:\n' >&2; cat "$CALLS" >&2; exit 1; fi
}

run image
grep -q 'kitty .* send-text' "$CALLS"
cmp "$PNG" "$FLASHPASTE_CAPTURE_DIR/flashpaste-clip-latest.png"
forbidden '^(x |wl --no-newline)'

run text
grep -q 'kitty .* action --self paste_from_clipboard' "$CALLS"
forbidden '^(x |wl --no-newline|.*send-text)'

: >"$CALLS"
status=0
MODE=text FLASHPASTE_CAPTURE_NAME=stale.png bash "$root/bin/flashpaste-capture-clip" >"$tmp/text-path" || status=$?
[ "$status" -eq 1 ]
[ ! -e "$FLASHPASTE_CAPTURE_DIR/stale.png" ]
forbidden '^x '

run image text
grep -q 'kitty .* action --self paste_from_clipboard' "$CALLS"
forbidden '^(x |wl )'

run silent
grep -q 'x .*TARGETS' "$CALLS"
grep -q 'kitty .* send-text' "$CALLS"
forbidden 'wl --no-newline|x .*text/plain'

FLASHPASTE_CAPTURE_NAME=fallback.png run fallback
grep -q 'x .*image/png' "$CALLS"
cmp "$PNG" "$FLASHPASTE_CAPTURE_DIR/fallback.png"

status=0
MODE=bad bash "$root/bin/flashpaste-capture-clip" >"$tmp/failed-path" || status=$?
[ "$status" -eq 2 ]
[ ! -s "$tmp/failed-path" ]
cmp "$PNG" "$FLASHPASTE_CAPTURE_DIR/flashpaste-clip-latest.png"
test -z "$(find "$FLASHPASTE_CAPTURE_DIR" -name '.flashpaste-capture.*' -print)"

echo 'Kitty clipboard hot-path tests passed'
