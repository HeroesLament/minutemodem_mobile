#!/usr/bin/env bash
# Bake the slow, app-code-independent native layer into the native-base image.
# ==========================================================================
# Runs INSIDE the Dockerfile.native-base RUN, on top of the ci-image toolchain.
# This is exactly build-apk.sh steps 1–6 (deps + patches + OTP install + Hamlib
# cross-build + `MobDev.NativeBuild.build_all`) with the signing/mob.release/
# Gradle/APK-collection steps removed — because those depend on app code.
#
# `build_all` installs the finished native library straight into
# android/app/src/main/jniLibs/<abi>/libminutemodem_mobile.so (via `zig build`,
# see mob_dev native_build.ex ~L235). That .so already has the NIFs + Hamlib
# statically linked in and is independent of the Elixir app code. We snapshot it
# (plus libsqlite3_nif.so) and the downloaded OTP runtime to stable paths the
# slimmed app-tier build restores from:
#
#   /opt/mob-bake/jniLibs/<abi>/*.so   ← the prebuilt native libs
#   $HOME/.mob/cache/otp-android-*     ← OTP runtime (image-native, stays put)
set -euo pipefail

SRC="$PWD"

# --- toolchain env (mirror build-apk.sh) ------------------------------------
export PATH="/opt/asdf/bin:/opt/asdf/shims:$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/java}"
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$(ls -d "$ANDROID_SDK_ROOT"/ndk/* 2>/dev/null | sort -V | tail -1)}}"
: "${ANDROID_NDK_HOME:?could not locate Android NDK under $ANDROID_SDK_ROOT/ndk}"

echo "== native-base bake — toolchain =="
elixir --version | tail -1
zig version
echo "NDK=$ANDROID_NDK_HOME"

# --- deps + local patches (same as build-apk.sh) ----------------------------
mix deps.get

( cd deps/mob && QUILT_PATCHES="$SRC/ci/patches/mob" quilt push -a )
grep -q "pub export fn mob_deliver_vendor_usb_control_result" \
  deps/mob/android/jni/mob_nif.zig \
  || { echo "!! mob vendor-usb patch did not apply"; exit 1; }

( cd deps/mob_dev && QUILT_PATCHES="$SRC/ci/patches/mob_dev" quilt push -a )
grep -q 'stage_empty_priv_otp_lib.*"hamlib_ex"' \
  deps/mob_dev/lib/mob_dev/native_build.ex \
  || { echo "!! mob_dev hamlib_ex staging patch did not apply"; exit 1; }

# --- OTP runtime bundles ($HOME/.mob/cache) ---------------------------------
mix mob.install

OTP="$(ls -d "$HOME"/.mob/cache/otp-android-* 2>/dev/null | grep -v arm32 | head -1)"
OTP_ARM32="$(ls -d "$HOME"/.mob/cache/otp-android-arm32-* 2>/dev/null | head -1)"
cat > android/local.properties <<EOF
sdk.dir=$ANDROID_SDK_ROOT
mob.otp_release=$OTP
mob.otp_release_arm32=${OTP_ARM32:-$OTP}
mob.mob_dir=$PWD/deps/mob
EOF

# --- hamlib_nif cross-compile env (same as build-apk.sh) --------------------
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android28-clang"
export HAMLIB_INCLUDE_DIR="$PWD/deps/hamlib_ex/android/hamlib/out/aarch64/usr/local/include"
export HAMLIB_LIB_DIR="$PWD/deps/hamlib_ex/android/hamlib/out/aarch64/usr/local/lib"
NDK_SYSROOT="$(dirname "$NDK_BIN")/sysroot"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_SYSROOT --target=aarch64-linux-android28"

# --- cross-build Hamlib (libhamlib.a + headers) -----------------------------
HL="$PWD/deps/hamlib_ex/android/hamlib"
rm -rf "$HL/out"
( cd "$HL" && NDK="$ANDROID_NDK_HOME" bash build-hamlib-android.sh aarch64 )
test -f "$HL/out/aarch64/usr/local/include/hamlib/rig.h" || { echo "!! hamlib headers missing"; exit 1; }
test -f "$HL/out/aarch64/usr/local/lib/libhamlib.a"      || { echo "!! libhamlib.a missing"; exit 1; }

# --- build_all → installs libminutemodem_mobile.so into jniLibs/<abi>/ -------
mix run --no-start -e 'r = MobDev.NativeBuild.build_all(platforms: [:android], slim: true); IO.inspect(r, label: "mob native build"); if r == false, do: System.halt(1)'

# --- snapshot the baked native layer ----------------------------------------
JL="android/app/src/main/jniLibs"
test -f "$JL/arm64-v8a/libminutemodem_mobile.so" \
  || { echo "!! build_all did not produce libminutemodem_mobile.so in jniLibs"; ls -la "$JL"/* || true; exit 1; }

mkdir -p /opt/mob-bake/jniLibs
cp -a "$JL"/. /opt/mob-bake/jniLibs/
git rev-parse HEAD > /opt/mob-bake/commit.txt 2>/dev/null || echo "unknown" > /opt/mob-bake/commit.txt
{
  echo "commit=$(cat /opt/mob-bake/commit.txt)"
  echo "otp=$(basename "$OTP")"
  echo "baked_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "libs:"; ls -la /opt/mob-bake/jniLibs/arm64-v8a/
} > /opt/mob-bake/manifest.txt

echo "== native-base baked =="
cat /opt/mob-bake/manifest.txt
