#!/usr/bin/env bash
# Best-effort Garage S3 artifact cache for the app tier.
# ====================================================================
# native-base already bakes ~/.hex + ~/.mix (deps download is a cache hit) and
# the prebuilt native .so. What it does NOT carry is the Gradle cache and the
# compiled Elixir `_build` — those are what this restores/saves to Garage so a
# wiped/rebuilt worker doesn't recompile everything from scratch.
#
# Deliberately best-effort: a miss, a missing client, or an S3 error must only
# slow the build, never fail it. Every path here exits 0.
#
# Usage: s3-cache.sh restore|save <key>
# Env (from task params): GARAGE_ENDPOINT GARAGE_KEY_ID GARAGE_SECRET
#                         CACHE_BUCKET (default ci-artifact-cache)
set -uo pipefail   # intentionally NOT -e — cache is best-effort

CMD="${1:?restore|save}"
KEY="${2:?cache key}"
: "${GARAGE_ENDPOINT:=}"
: "${GARAGE_KEY_ID:=}"
: "${GARAGE_SECRET:=}"
: "${CACHE_BUCKET:=ci-artifact-cache}"

if [ -z "$GARAGE_ENDPOINT" ] || [ -z "$GARAGE_KEY_ID" ] || [ -z "$GARAGE_SECRET" ]; then
  echo "[s3-cache] no Garage endpoint/creds — skipping $CMD"; exit 0
fi

# mc (MinIO client) is S3-compatible and speaks to Garage. Baking it into
# ci-image is a future optimisation; for now fetch it best-effort at runtime.
MC=/usr/local/bin/mc
if ! command -v mc >/dev/null 2>&1; then
  if curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o "$MC" 2>/dev/null; then
    chmod +x "$MC" 2>/dev/null || true
  fi
fi
command -v mc >/dev/null 2>&1 || { echo "[s3-cache] mc unavailable — skipping $CMD"; exit 0; }
mc alias set gc "$GARAGE_ENDPOINT" "$GARAGE_KEY_ID" "$GARAGE_SECRET" --api S3v4 >/dev/null 2>&1 \
  || { echo "[s3-cache] mc alias failed — skipping $CMD"; exit 0; }

# name → "<tar -C dir> <relative subdir>"
entry() {
  case "$1" in
    gradle) echo "$HOME .gradle/caches" ;;
    build)  echo "$PWD _build" ;;
  esac
}

for name in gradle build; do
  # shellcheck disable=SC2046
  set -- $(entry "$name"); DIR="$1"; SUB="$2"
  OBJ="gc/$CACHE_BUCKET/$KEY-$name.tgz"
  case "$CMD" in
    restore)
      if mc stat "$OBJ" >/dev/null 2>&1; then
        echo "[s3-cache] restoring $name from $OBJ"
        mc cat "$OBJ" 2>/dev/null | tar -xz -C "$DIR" 2>/dev/null \
          && echo "[s3-cache] $name restored" \
          || echo "[s3-cache] $name restore failed (ignored)"
      else
        echo "[s3-cache] miss: $name ($KEY)"
      fi
      ;;
    save)
      if [ -d "$DIR/$SUB" ]; then
        echo "[s3-cache] saving $name -> $OBJ"
        tar -cz -C "$DIR" "$SUB" 2>/dev/null | mc pipe "$OBJ" >/dev/null 2>&1 \
          && echo "[s3-cache] $name saved" \
          || echo "[s3-cache] $name save failed (ignored)"
      else
        echo "[s3-cache] $name: $DIR/$SUB absent — nothing to save"
      fi
      ;;
  esac
done
exit 0
