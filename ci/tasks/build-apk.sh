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

# ── Apply local mob patches (vendor-USB control transfer / PTT) ──────────────
# Pristine hex `mob 0.7.5` ships 6 of the 7 mob_deliver_vendor_usb_* exports.
# The CP2102 control-transfer + PTT work adds the 7th (control_result) plus its
# Elixir (lib/mob/vendor_usb.ex) and Erlang (src/mob_nif.erl) plumbing. Rather
# than fork mob, carry the delta as a quilt patch stack (ci/patches/mob) and
# push it onto the freshly-fetched dep before any native build. Without it,
# beam_jni.c references an undefined mob_deliver_vendor_usb_control_result and
# libminutemodem_mobile.so fails to dlopen (UnsatisfiedLinkError at launch).
( cd deps/mob && QUILT_PATCHES="$SRC/ci/patches/mob" quilt push -a )
grep -q "pub export fn mob_deliver_vendor_usb_control_result" \
  deps/mob/android/jni/mob_nif.zig \
  || { echo "!! mob vendor-usb patch did not apply (control_result missing)"; exit 1; }

# ── Apply local mob_dev patch (stage hamlib_ex as an on-device OTP lib) ──────
# Pristine hex `mob_dev 0.5.6` stages exqlite/nx_eigen as OTP libs but NOT
# hamlib_ex (a custom NIF dep). hamlib_ex's NIF does `use Rustler, otp_app:
# :hamlib_ex`, so at load time Rustler calls :code.priv_dir(:hamlib_ex). Without
# a staged lib/hamlib_ex-<vsn>/ dir that returns {:error, :bad_name}, the NIF
# never attaches, and Hamlib.Nif.list_models/0 falls to its not-loaded stub —
# the rig model picker shows "0 rigs". The local deps/mob_dev is patched to
# stage it (both build_all + deploy paths); carry that delta here too.
( cd deps/mob_dev && QUILT_PATCHES="$SRC/ci/patches/mob_dev" quilt push -a )
grep -q 'stage_empty_priv_otp_lib.*"hamlib_ex"' \
  deps/mob_dev/lib/mob_dev/native_build.ex \
  || { echo "!! mob_dev hamlib_ex staging patch did not apply"; exit 1; }

# ── Tier 1 fast-path: consume the baked native layer if present ──────────────
# On the native-base image, build-native-base already ran the hamlib cross-build
# + build_all and staged the finished libminutemodem_mobile.so (+ libsqlite3_nif)
# to /opt/mob-bake/jniLibs, with the OTP runtime baked into $HOME/.mob/cache.
# Restore the .so into jniLibs/ (Gradle's CMake imports it) and skip the slow
# native steps. Absent (running on plain ci-image) → full native build below.
if [ -d /opt/mob-bake/jniLibs ]; then
  echo "== native-base detected — restoring baked native layer (skipping hamlib + build_all) =="
  mkdir -p android/app/src/main/jniLibs
  cp -a /opt/mob-bake/jniLibs/. android/app/src/main/jniLibs/
  ls -la android/app/src/main/jniLibs/*/ | sed -n '1,12p'
  NATIVE_BAKED=1
fi

# Download the Android OTP runtime bundles (into $HOME/.mob/cache).
# No-op on native-base (the cache is already baked in); a full download on ci-image.
mix mob.install

# android/local.properties is machine-specific + gitignored, and mob.install
# doesn't reliably leave one Gradle picks up in CI. Write it explicitly from the
# bundles just downloaded: the JNI CMakeLists needs ${MOB_DIR} to find
# mob_nif.c, and the build links against the OTP release (libbeam.a).
OTP="$(ls -d "$HOME"/.mob/cache/otp-android-* 2>/dev/null | grep -v arm32 | head -1)"
OTP_ARM32="$(ls -d "$HOME"/.mob/cache/otp-android-arm32-* 2>/dev/null | head -1)"
cat > android/local.properties <<EOF
sdk.dir=$ANDROID_SDK_ROOT
mob.otp_release=$OTP
mob.otp_release_arm32=${OTP_ARM32:-$OTP}
mob.mob_dir=$PWD/deps/mob
EOF
echo "--- android/local.properties ---"; cat android/local.properties

# ── Full native build — plain ci-image only; skipped when the layer was baked ─
if [ -z "${NATIVE_BAKED:-}" ]; then

# hamlib_nif's build.rs (cc-rs + bindgen, statically linking the cross-built
# libhamlib.a) needs the NDK aarch64 toolchain + the hamlib install tree. mob.exs
# supplies these via nif_build_env, but that config isn't picked up in this CI
# invocation, so export them explicitly. Paths point at the committed cross-built
# hamlib under deps/hamlib_ex (the git dep), which exists in CI.
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC_aarch64_linux_android="$NDK_BIN/aarch64-linux-android28-clang"
export AR_aarch64_linux_android="$NDK_BIN/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$NDK_BIN/aarch64-linux-android28-clang"
export HAMLIB_INCLUDE_DIR="$PWD/deps/hamlib_ex/android/hamlib/out/aarch64/usr/local/include"
export HAMLIB_LIB_DIR="$PWD/deps/hamlib_ex/android/hamlib/out/aarch64/usr/local/lib"

# hamlib_nif's build.rs runs bindgen over hamlib_shim.h. cc-rs compiles the C
# shim with the NDK clang (which knows its own sysroot), but bindgen invokes
# libclang directly and defaults to the HOST include paths — so it tries to
# parse the glibc /usr/include/stdint.h and dies on bits/libc-header-start.h.
# Point bindgen at the NDK sysroot + target for the Android build ONLY (a
# target-scoped var, so the host mix-compile pass keeps its own headers). Both
# underscore spelling — the hyphenated triple isn't a valid shell identifier so
# `export` rejects it, and bindgen (>=0.63) checks the underscore variant too
# (both appear in the crate's rerun-if-env-changed list).
NDK_SYSROOT="$(dirname "$NDK_BIN")/sysroot"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android="--sysroot=$NDK_SYSROOT --target=aarch64-linux-android28"
echo "--- NIF cross-compile env ---"; echo "CC=$CC_aarch64_linux_android"; echo "HAMLIB_LIB_DIR=$HAMLIB_LIB_DIR"; echo "NDK_SYSROOT=$NDK_SYSROOT"

# Cross-build Android hamlib (libhamlib.a + headers). Only the recipe is in VCS,
# not its output (android/hamlib/out is a symlink to a local build), so a clean
# checkout must build it: the script clones Hamlib 4.6.5 and cross-compiles with
# the NDK into out/aarch64/usr/local, which HAMLIB_INCLUDE_DIR/LIB_DIR point at.
HL="$PWD/deps/hamlib_ex/android/hamlib"
rm -rf "$HL/out"
( cd "$HL" && NDK="$ANDROID_NDK_HOME" bash build-hamlib-android.sh aarch64 )
test -f "$HL/out/aarch64/usr/local/include/hamlib/rig.h" || { echo "!! hamlib headers missing after build"; exit 1; }
test -f "$HL/out/aarch64/usr/local/lib/libhamlib.a" || { echo "!! libhamlib.a missing after build"; exit 1; }

# Cross-compile the native NIFs to zig object files (zig-out/<abi>/*.o). This is
# the piece `mix mob.deploy --native` runs via MobDev.NativeBuild.build_all/1 —
# `mix mob.release` does NOT do it. Without these, the JNI CMakeLists falls back
# to a nonexistent .c path (mob ships .zig NIF glue) and Gradle fails. We call
# build_all directly to skip mob.deploy's device-push/compat logic (no device
# in CI). Halt on any {:error, _} so a NIF build failure fails the CI step.
mix run --no-start -e 'r = MobDev.NativeBuild.build_all(platforms: [:android], slim: true); IO.inspect(r, label: "mob native build"); if r == false, do: System.halt(1)'

fi  # NATIVE_BAKED — end of the full native build block

# Produces the signed AAB (Gradle now finds the zig-built NIF objects).
mix mob.release --android

# Signed, sideloadable APK.
( cd android && ./gradlew --no-daemon assembleRelease )

# --- collect artifacts + version --------------------------------------------
APK="android/app/build/outputs/apk/release/app-release.apk"
AAB="android/app/build/outputs/bundle/release/app-release.aab"

test -f "$APK" || { echo "!! APK not found at $APK"; exit 1; }

SHA="$(git rev-parse --short HEAD)"

# Version source depends on the flow (see VERSION_MODE param):
#   tag       — prod release off a v* tag; VER = the exact tag (e.g. v1.2.3).
#   timestamp — dev prerelease; VER = build-<UTC>-<sha> (default).
case "${VERSION_MODE:-timestamp}" in
  tag)
    VER="$(git describe --tags --exact-match 2>/dev/null || true)"
    [ -n "$VER" ] || { echo "!! VERSION_MODE=tag but HEAD has no exact tag"; exit 1; }
    ;;
  *)
    VER="build-$(date -u +%Y%m%d-%H%M%S)-${SHA}"
    ;;
esac

cp "$APK" "$OUT/minutemodem-${VER}.apk"
[ -f "$AAB" ] && cp "$AAB" "$OUT/minutemodem-${VER}.aab" || echo "(no AAB — APK only)"

echo "$VER"        > "$OUT/version.txt"
git rev-parse HEAD > "$OUT/commit.txt"

echo "== built ${VER} =="
ls -la "$OUT"
