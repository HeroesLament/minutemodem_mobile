#!/usr/bin/env bash
# Build the signed release APK + AAB inside the CI image.
# Concourse lays inputs/outputs out as siblings of the task cwd:
#   ./repo/        (git input)
#   ./artifacts/   (output — the APK/AAB land here)
set -euo pipefail

ROOT="$PWD"
SRC="$ROOT/repo"
OUT="$ROOT/artifacts"
mkdir -p "$OUT"

# --- toolchain (image already has asdf shims + pinned versions) -------------
export PATH="/opt/asdf/bin:/opt/asdf/shims:$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/java}"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

echo "== toolchain =="
elixir --version | tail -1
java -version 2>&1 | head -1
zig version

cd "$SRC"

# --- restore signing material (from OpenBao-provided params) ----------------
: "${KEYSTORE_B64:?missing KEYSTORE_B64}"
: "${KEYSTORE_STORE_PASSWORD:?missing KEYSTORE_STORE_PASSWORD}"
: "${KEYSTORE_KEY_ALIAS:?missing KEYSTORE_KEY_ALIAS}"
: "${KEYSTORE_KEY_PASSWORD:?missing KEYSTORE_KEY_PASSWORD}"

KS="/tmp/release.jks"
echo "$KEYSTORE_B64" | base64 -d > "$KS"

# android/keystore.properties is what android/app/build.gradle reads. An
# absolute storeFile avoids the file() relative-path ambiguity.
cat > android/keystore.properties <<EOF
storeFile=$KS
storePassword=$KEYSTORE_STORE_PASSWORD
keyAlias=$KEYSTORE_KEY_ALIAS
keyPassword=$KEYSTORE_KEY_PASSWORD
EOF

# Always scrub signing material, even on failure.
cleanup() { rm -f "$KS" android/keystore.properties; }
trap cleanup EXIT

# --- build ------------------------------------------------------------------
mix deps.get

# Produces the signed AAB and populates android/local.properties with the Mob
# OTP-runtime paths the subsequent Gradle APK build also relies on.
mix mob.release --android

# Signed, sideloadable APK.
( cd android && ./gradlew --no-daemon assembleRelease )

# --- collect artifacts + version --------------------------------------------
APK="android/app/build/outputs/apk/release/app-release.apk"
AAB="android/app/build/outputs/bundle/release/app-release.aab"

test -f "$APK" || { echo "!! APK not found at $APK"; exit 1; }

SHA="$(git rev-parse --short HEAD)"
VER="build-$(date -u +%Y%m%d-%H%M%S)-${SHA}"

cp "$APK" "$OUT/minutemodem-${VER}.apk"
[ -f "$AAB" ] && cp "$AAB" "$OUT/minutemodem-${VER}.aab" || echo "(no AAB — APK only)"

echo "$VER"        > "$OUT/version.txt"
git rev-parse HEAD > "$OUT/commit.txt"

echo "== built ${VER} =="
ls -la "$OUT"
