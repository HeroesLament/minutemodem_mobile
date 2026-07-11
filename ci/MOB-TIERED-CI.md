# Tiered CI for Mob-on-Android builds

A pattern for making [Mob](https://github.com/mobile-dev-inc/mob) Android CI
builds fast by baking the slow, app-code-independent native layer into a
container image, so an app-only commit skips it entirely.

Written from getting MinuteModem (an HF-radio controller: Mob + a Rust/zig
`hamlib_nif` + `phy_modem`) building on self-hosted Concourse. If you're doing
Mob-on-Android CI, this may save you the archaeology.

## The problem

A from-clean Mob Android build does a lot, and most of it doesn't change when
you only touched Elixir:

1. `mix deps.get`
2. `mix mob.install` — downloads the Android **OTP runtime** bundles into
   `$HOME/.mob/cache/otp-android-*`.
3. Cross-build any native C deps (for us, **Hamlib** with the NDK — minutes).
4. `MobDev.NativeBuild.build_all(platforms: [:android])` — runs `zig build`
   per-ABI, which compiles the static NIFs and **installs the finished
   `libminutemodem_mobile.so` into `android/app/src/main/jniLibs/<abi>/`**.
5. `mix mob.release --android` — assembles the OTP release (your app beams).
6. `./gradlew assembleRelease` — packages the `.so` + release into the APK.

Steps 2–4 are the expensive, rarely-changing part. An app-only commit re-does
all of it for no reason.

## The key insight

`build_all`'s output — `libminutemodem_mobile.so` — is the embedded BEAM plus
your **statically linked NIFs** (and, for us, Hamlib linked in). Your Elixir
**app code is not in the `.so`** — it lives in the OTP release that
`mob.release` assembles. So the `.so` only changes when `native/**`, the OTP
version, a native C dep, or Mob's zig glue changes — *not* on an app commit.

And Mob's generated `android/app/src/main/jni/CMakeLists.txt` consumes it in
priority order:

1. `jniLibs/<abi>/libminutemodem_mobile.so` exists → **imported as-is, native
   build skipped**;
2. else `android/app/build/zig-out/<abi>/*.o` → CMake links them;
3. else compile `.c` sources.

Since `mob.release` does **not** run `build_all`, if the `.so` is already in
`jniLibs/`, Gradle just imports it. That's the whole trick: **bake the `.so` +
the OTP cache; the app build restores them and runs only `mob.release` +
Gradle.**

## The three tiers

- **ci-image** — OS + asdf toolchain (Erlang/Elixir/zig) + Android SDK/NDK.
  Rebuilds on `.tool-versions` / Dockerfile changes. Basically never.
- **native-base** — `FROM ci-image`, plus the baked outputs of steps 2–4:
  `jniLibs/<abi>/*.so` staged to a stable path (`/opt/mob-bake/jniLibs`) and the
  OTP cache (`$HOME/.mob/cache`, image-native). Rebuilds only on native inputs.
- **app build** — `FROM native-base`. The build script auto-detects the baked
  layer, copies the `.so` back into `jniLibs/`, and skips steps 3–4:

  ```sh
  if [ -d /opt/mob-bake/jniLibs ]; then
    cp -a /opt/mob-bake/jniLibs/. android/app/src/main/jniLibs/
    NATIVE_BAKED=1          # guards the hamlib cross-build + build_all block
  fi
  ```

`mix mob.install` stays in the app build but is a **no-op** on native-base (the
OTP cache is already there). `~/.hex` / `~/.mix` are likewise baked, so
`deps.get` is a cache hit.

Result: the ~10 min of native work drops out of every app build. Only a native
change (a path-filtered trigger) rebuilds native-base, and the app build
cascades onto the new image.

## Backends

- **Images + buildkit layer cache → an OCI registry (Harbor).** buildkit layers
  are OCI content, so `--export-cache type=registry,mode=max` to a `:buildcache`
  tag is their natural home — the registry manages GC/retention and reuses the
  image push creds.
- **App-tier caches (Gradle, `_build`) → S3 (Garage).** These are plain tarballs,
  not OCI layers, so they go to an object store, restored by key so a wiped
  worker restores instead of recompiling.

## Gotchas we hit (so you don't)

- **buildkit direct-push breaks Concourse `passed:`.** If you push the image
  from buildkit (not a Concourse `put`), the registry-image resource's versions
  aren't outputs of the build job, so `passed:` finds nothing. Cascade on
  `get: <upstream-image>` with `trigger: true` instead.
- **`mode=max` cache export can `context deadline exceeded`** on a multi-GB
  image (it pushes *every* intermediate layer). Mark it best-effort:
  `--export-cache type=registry,ref=…,mode=max,ignore-error=true`. The image
  push finishes first, so the image is fine even if the cache export times out.
- **oci-build-task's tarball export** also trips `context deadline exceeded` on
  a big image — prefer buildkit `--output type=image,push=true` (streams layers
  to the registry) over exporting a giant local `image.tar` that a `put` then
  re-uploads.
- **buildkitd's registry `ca=` doesn't cover the OAuth token fetch.** For a
  private CA, buildkitd's `POST /service/token` goes through Go's system trust —
  point `SSL_CERT_FILE` at a bundle that includes your CA, not just the
  per-registry `ca=`.
- **A bare buildkitd runs RUN steps without host networking** → apt/curl crawl.
  `--oci-worker-net=host` fixes it.
- **A crashed worker can wedge.** After an unclean host crash, a Concourse
  worker's container writable layer can corrupt so containerd won't start
  (`context canceled` on boot) — survives restarts *and* a host reboot. Recreate
  the worker container (`podman-compose up --force-recreate`) to reset it.
- **Thin-provisioned VM storage needs `discard=on`** to return freed guest space
  to the pool; otherwise big image pushes fill it one-way and io-error the VM.
