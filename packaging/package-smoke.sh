#!/usr/bin/env bash
# Smoke-test a built flashpaste .deb in a clean Ubuntu container.
#
# CI builds dist/flashpaste_<version>_all.deb and the stable alias
# dist/flashpaste_all.deb. This script installs the stable alias in a
# fresh image and asserts the package layout that downstream users and
# release automation depend on.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEB="${1:-$REPO_DIR/dist/flashpaste_all.deb}"
IMAGE="${FLASHPASTE_SMOKE_IMAGE:-ubuntu:24.04}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 || die "docker not found"
[ -s "$DEB" ] || die "missing stable package asset: $DEB"

case "$DEB" in
  "$REPO_DIR"/*) container_deb="/work/${DEB#"$REPO_DIR"/}" ;;
  *) die "package path must live under repo: $DEB" ;;
esac

docker run --rm \
  -v "$REPO_DIR:/work:ro" \
  "$IMAGE" \
  bash -s -- "$container_deb" <<'EOF'
set -euo pipefail

deb="$1"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y --no-install-recommends "$deb"

test -x /usr/bin/tmux-paste-dispatch
test -x /usr/bin/flashpaste-capture-clip
test -f /usr/lib/systemd/user/flashpasted.service
test -s /work/dist/flashpaste_all.deb

test "$(flashpaste paths --bash-dispatcher)" = "/usr/bin/tmux-paste-dispatch"
test "$(flashpaste paths --paste-image)" = "/usr/share/flashpaste/paste_image.sh"
test "$(flashpaste paths --systemd-unit-mode)" = "user"
EOF
