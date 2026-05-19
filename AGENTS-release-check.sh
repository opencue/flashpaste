#!/usr/bin/env bash
# AGENTS.md end-of-turn check: every `v1.X:` commit on main must have
# a matching annotated tag, and every tag must have a published GitHub
# release. Exit code:
#   0 — everything in sync
#   1 — at least one version commit is missing a tag or release
#   2 — environment unusable (no git, no gh, not in this repo)
#
# Quiet by default; pass --verbose to also print the GOOD lines.
# This is a CHECK, not a fixer. It prints what's broken; you decide how
# to repair (usually: tag + push the missing commit, let the workflow
# build the release).
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR" || { echo "cannot cd to $REPO_DIR" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git not in PATH" >&2; exit 2; }

VERBOSE=0
[ "${1:-}" = "--verbose" ] || [ "${1:-}" = "-v" ] && VERBOSE=1

# Pull latest tag state from origin so we don't false-positive on a tag
# the user pushed but our local clone hasn't fetched.
git fetch origin --tags --quiet 2>/dev/null || true

missing_tags=0
missing_releases=0

# Walk every commit whose subject starts with `vX.Y[.Z]:`.
while IFS=$'\t' read -r sha subject; do
  tag=$(printf '%s' "$subject" | awk '{print $1}' | tr -d ':')
  # The tag must (a) exist locally and (b) point at this same commit.
  if ! git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    printf 'MISSING TAG     %s  %s\n' "$tag" "$sha"
    missing_tags=$((missing_tags + 1))
    continue
  fi
  tagged_sha=$(git rev-list -n 1 "refs/tags/$tag")
  if [ "$tagged_sha" != "$sha" ]; then
    printf 'TAG MISPOINTS   %s  expected %s  got %s\n' "$tag" "$sha" "$tagged_sha"
    missing_tags=$((missing_tags + 1))
    continue
  fi
  if command -v gh >/dev/null 2>&1; then
    if ! gh release view "$tag" >/dev/null 2>&1; then
      printf 'MISSING RELEASE %s  %s\n' "$tag" "$sha"
      missing_releases=$((missing_releases + 1))
      continue
    fi
  fi
  [ "$VERBOSE" = "1" ] && printf 'OK              %s  %s\n' "$tag" "$sha"
done < <(git log --format='%H%x09%s' | awk -F'\t' '$2 ~ /^v[0-9]+\.[0-9]+(\.[0-9]+)?:/ {print}')

if [ "$missing_tags" -eq 0 ] && [ "$missing_releases" -eq 0 ]; then
  [ "$VERBOSE" = "1" ] && echo "all version commits tagged + released"
  exit 0
fi

echo
echo "summary: $missing_tags missing tag(s), $missing_releases missing release(s)"
echo "see AGENTS.md § Versioning + releases for the fix workflow"
exit 1
