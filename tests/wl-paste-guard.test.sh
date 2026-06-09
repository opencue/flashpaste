#!/usr/bin/env bash
# Behavioral regression test for bin/wl-paste's image-coexistence guard.
#
# This is the net under the bug class that kept reaching the user: image
# bytes / blob-<img> markup pasted as text. The guard says: when the
# clipboard carries an image, text-oriented reads return NOTHING (so Claude
# attaches the image and inserts no markup).
#
# Headless + non-intrusive: mocks `xclip` via PATH and forces the shim's
# wedge fast-path (private XDG_RUNTIME_DIR + cache file), so it never touches
# the real clipboard and needs no display. Safe to run in CI.
set -u

HERE="$(cd "$(dirname -- "$0")" && pwd)"
SHIM="$HERE/../bin/wl-paste"
[ -x "$SHIM" ] || { echo "FATAL: shim not found at $SHIM"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/run"

# Fake xclip: TARGETS from $FAKE_TARGETS; content as CONTENT:<target>.
cat > "$T/bin/xclip" <<'EOF'
#!/usr/bin/env bash
tgt=""
while [ $# -gt 0 ]; do case "$1" in
  -selection) shift 2;;
  -t) tgt="$2"; shift 2;;
  *) shift;;
esac; done
if [ "$tgt" = "TARGETS" ]; then printf '%s\n' $FAKE_TARGETS; exit 0; fi
if [ -n "$tgt" ]; then printf 'CONTENT:%s' "$tgt"; else printf 'CONTENT:default'; fi
EOF
chmod +x "$T/bin/xclip"

export XDG_RUNTIME_DIR="$T/run"
: > "$T/run/clip-wayland-wedge"   # force wedged → no real wl-paste call
export PATH="$T/bin:$PATH"

pass=0; fail=0
check() { # desc expected actual
  if [ "$2" = "$3" ]; then echo "ok   - $1"; pass=$((pass+1))
  else echo "FAIL - $1 : expected [$2] got [$3]"; fail=$((fail+1)); fi
}

out=$(FAKE_TARGETS="TARGETS image/png text/html" bash "$SHIM" -t text/html); rc=$?
check "text/html suppressed when image present (empty)" "" "$out"
check "text/html suppressed -> rc=1" "1" "$rc"

out=$(FAKE_TARGETS="TARGETS image/png text/html" bash "$SHIM" -t image/png)
check "image/png still returned when image present" "CONTENT:image/png" "$out"

out=$(FAKE_TARGETS="TARGETS UTF8_STRING text/plain" bash "$SHIM" -t text/plain)
check "text/plain returned when no image" "CONTENT:text/plain" "$out"

out=$(FAKE_TARGETS="TARGETS UTF8_STRING text/plain" bash "$SHIM")
check "default text returned when no image" "CONTENT:default" "$out"

out=$(FAKE_TARGETS="TARGETS image/png text/html" bash "$SHIM" -l | tr '\n' ',')
check "list-types not suppressed" "TARGETS,image/png,text/html," "$out"

out=$(FAKE_TARGETS="TARGETS image/png" bash "$SHIM")
check "default text suppressed when image present" "" "$out"

echo "--- wl-paste-guard: PASS=$pass FAIL=$fail"
[ "$fail" = "0" ]
