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
