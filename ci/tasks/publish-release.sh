#!/usr/bin/env bash
# Create a GitHub release from the staged artifacts using the gh CLI.
# gh authenticates from $GH_TOKEN; the tag is created at the built commit.
set -euo pipefail

: "${GH_TOKEN:?missing GH_TOKEN}"
: "${GH_REPO:?missing GH_REPO}"

OUT="$PWD/artifacts"
VER="$(cat "$OUT/version.txt")"
SHA="$(cat "$OUT/commit.txt")"

# Collect artifacts: APK always, AAB if present.
FILES=( "$OUT"/minutemodem-*.apk )
for f in "$OUT"/minutemodem-*.aab; do
  [ -e "$f" ] && FILES+=("$f")
done

echo "Publishing $VER ($SHA) to $GH_REPO:"
printf '  %s\n' "${FILES[@]}"

# `gh release create <tag>` creates the tag at --target if it doesn't exist.
# --prerelease: manual dev builds aren't promoted stable releases.
gh release create "$VER" \
  --repo "$GH_REPO" \
  --target "$SHA" \
  --title "MinuteModem $VER" \
  --notes "Automated Concourse build from ${SHA} (manual trigger)." \
  --prerelease \
  "${FILES[@]}"

echo "== published $VER =="

# ── Prune older prereleases — keep only the one just published ───────────────
# Testers pull "the latest prerelease", so old dev builds are just clutter.
# Delete every OTHER prerelease (and its git tag); full/stable releases are
# never touched (select .isPrerelease). Runs after a successful create so a
# publish failure never removes the previous good build.
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
