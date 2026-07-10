#!/usr/bin/env bash
# Create a GitHub release from the staged artifacts using the gh CLI.
# gh authenticates from $GH_TOKEN; the tag is created at the built commit.
set -euo pipefail

: "${GH_TOKEN:?missing GH_TOKEN}"
: "${GH_REPO:?missing GH_REPO}"
PRERELEASE="${PRERELEASE:-true}"
PRUNE_PRERELEASES="${PRUNE_PRERELEASES:-false}"

OUT="$PWD/artifacts"
VER="$(cat "$OUT/version.txt")"
SHA="$(cat "$OUT/commit.txt")"

# Collect artifacts: APK always, AAB if present.
FILES=( "$OUT"/minutemodem-*.apk )
for f in "$OUT"/minutemodem-*.aab; do
  [ -e "$f" ] && FILES+=("$f")
done

# Two flows share this script:
#   PRERELEASE=true  — dev branch commit; a marked prerelease, VER is the
#                      build-<UTC>-<sha> tag (created at --target SHA).
#   PRERELEASE=false — prod release; VER is a v* git tag that already exists,
#                      published as a full (latest) Release.
FLAGS=()
if [ "$PRERELEASE" = "true" ]; then
  FLAGS+=(--prerelease)
  NOTES="Automated Concourse prerelease from ${SHA} (dev branch)."
else
  FLAGS+=(--latest)
  NOTES="MinuteModem ${VER} — automated Concourse release from ${SHA}."
fi

echo "Publishing $VER ($SHA) to $GH_REPO (prerelease=$PRERELEASE):"
printf '  %s\n' "${FILES[@]}"

# `gh release create <tag>` uses an existing tag (v* prod releases) or creates
# it at --target when absent (dev prereleases).
gh release create "$VER" \
  --repo "$GH_REPO" \
  --target "$SHA" \
  --title "MinuteModem $VER" \
  --notes "$NOTES" \
  "${FLAGS[@]}" \
  "${FILES[@]}"

echo "== published $VER =="

# ── Prune older prereleases — keep only the one just published ───────────────
# Dev only (PRUNE_PRERELEASES=true): testers pull "the latest prerelease", so
# old dev builds are clutter. Only ever deletes prereleases (select
# .isPrerelease) — full/stable Releases are never touched. Guarded off for the
# prod release flow so a tagged release never removes the dev prereleases.
if [ "$PRUNE_PRERELEASES" != "true" ]; then
  echo "(prune disabled — PRUNE_PRERELEASES=$PRUNE_PRERELEASES)"
  exit 0
fi
echo "Pruning old prereleases (keeping $VER)…"
# mapfile + process substitution (not a pipe) so a no-match grep can't trip
# `set -o pipefail` and fail the build when there's nothing to prune.
mapfile -t OLD < <(
  gh release list --repo "$GH_REPO" --limit 200 \
    --json tagName,isPrerelease \
    --jq '.[] | select(.isPrerelease) | .tagName' \
  | grep -vxF "$VER" || true
)
for old in "${OLD[@]}"; do
  [ -n "$old" ] || continue
  echo "  deleting old prerelease: $old"
  gh release delete "$old" --repo "$GH_REPO" --yes --cleanup-tag
done

echo "== prune complete (removed ${#OLD[@]}) =="
