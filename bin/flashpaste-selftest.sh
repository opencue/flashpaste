#!/usr/bin/env bash
# flashpaste self-test — one command that proves the paste pipeline's
# correctness guards still hold. Runs the behavioral regression suite (the
# net under the image-bytes-as-text / blob-markup bug class) plus, with
# --rust, the daemon's unit tests.
#
#   flashpaste-selftest.sh           behavioral bash tests only (fast, no build)
#   flashpaste-selftest.sh --rust    also `cargo test -p flashpasted`
#
# Exits non-zero if any test fails. Headless-safe: the bash tests mock the
# clipboard, so this never touches the user's real selection and needs no
# display. Wired into CI (.github/workflows/lint.yml) and callable from
# flashpaste-doctor.
set -u

ROOT="$(cd "$(dirname -- "$0")/.." && pwd)"
fail=0

echo "── flashpaste self-test ───────────────────────────────────"
for t in "$ROOT"/tests/*.test.sh; do
  [ -f "$t" ] || continue
  echo
  echo "▶ $(basename "$t")"
  if bash "$t"; then :; else fail=1; fi
done

if [ "${1:-}" = "--rust" ]; then
  echo
  echo "▶ cargo test -p flashpasted"
  if cargo test --manifest-path "$ROOT/rs/Cargo.toml" -p flashpasted 2>&1 | tail -3; then :; else fail=1; fi
fi

echo
if [ "$fail" = "0" ]; then
  echo "✓ flashpaste self-test: ALL PASSED"
else
  echo "✗ flashpaste self-test: FAILURES (see above)"
fi
exit "$fail"
