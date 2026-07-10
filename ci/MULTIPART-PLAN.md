# Multipart CI build — plan

Splitting the MinuteModem Android CI build into cache-friendly tiers so that an
app-only commit no longer re-does the slow native work (cross-building Hamlib,
downloading the Android OTP runtime, cross-compiling the Rust/zig NIFs).

This is somewhat new ground for Mob-on-Android CI, so the plan is written to be
executed in small, independently verifiable steps — and to double as a
reference others in the Mob community can follow.

## Goal

- **Fast common case:** an Elixir/app-only commit builds in a few minutes, not ~15.
- **Resilient caches:** a wiped/rebuilt Concourse worker doesn't force a full
  native rebuild from scratch (this bit us during the July storage incident).

## Where we are now (the monolith)

`ci/tasks/build-apk.sh` currently does everything on every commit, inside the
`ci-image` toolchain container:

1. `mix deps.get`
2. Apply local quilt patches to `deps/mob` and `deps/mob_dev`
   (`ci/patches/**`) — vendor-USB control transfer + the hamlib_ex OTP-lib
   staging fix.
3. `mix mob.install` — downloads the Android OTP runtime bundles into
   `$HOME/.mob/cache/otp-android-*`.
4. Write `android/local.properties` (points Gradle at the OTP bundles + mob dir).
5. Cross-build Hamlib 4.6.5 with the NDK →
   `deps/hamlib_ex/android/hamlib/out/aarch64/usr/local/{lib,include}`.
6. `MobDev.NativeBuild.build_all(platforms: [:android], slim: true)` —
   cross-compiles the native NIFs (`phy_modem`, `hamlib_nif`) to `zig-out/<abi>/*.o`.
7. `mix mob.release --android` — builds the signed AAB (Gradle consumes the
   zig-built NIF objects + the OTP release).
8. `./gradlew assembleRelease` — the sideloadable APK.

By how often each piece actually changes:

| Piece | Changes when | Today |
|---|---|---|
| NDK/SDK, Erlang/Elixir/zig pins | `.tool-versions` / Dockerfile | baked in `ci-image` ✅ |
| Android OTP runtime (step 3) | OTP/mob pin bump | re-downloaded every build |
| Hamlib `libhamlib.a` (step 5) | Hamlib version / recipe | re-cross-built every build |
| Native NIF objects (step 6) | `native/**`, crate deps | re-compiled every build |
| App Elixir code (step 7) | every commit | (unavoidable) |
| Gradle assemble (step 8) | every commit | (unavoidable) |

Steps 3, 5, 6 are the expensive, rarely-changing work we want to lift out.

## Target architecture

### Three image tiers (each rebuilt only on its own inputs)

- **Tier 0 — `ci-image`** *(exists)*: Debian + asdf toolchain
  (Erlang/Elixir/zig) + Android SDK/NDK + `gh`. Built by `build-ci-image`,
  triggered by `ci/Dockerfile` / `.tool-versions` / `ci/tasks/build-ci-image.sh`.
- **Tier 1 — `minutemodem-native-base`** *(new)*: `FROM ci-image`, plus the
  baked outputs of steps 3, 5, 6:
  - the Android OTP runtime cache (`$HOME/.mob/cache/otp-android-*`),
  - the cross-built Hamlib tree,
  - the prebuilt native NIF objects (`zig-out/<abi>/*.o`).
  Built by a new `build-native-base` job, `passed: [build-ci-image]`,
  triggered only by native inputs (see resource below).
- **Tier 2 — the app build** (`dev-prerelease` / `tagged-release`):
  `image: native-base`, `passed: [build-native-base]`. A slimmed
  `build-apk.sh` that keeps deps.get + patches + `mob.release` + Gradle and
  **drops steps 3, 5, 6** (their outputs come from the image).

`passed:` gates make a lower-tier change cascade upward automatically, while an
app commit only runs Tier 2.

### Two caches, two idiomatic backends

- **buildkit *layer* cache → Harbor (registry).** buildkit layers are OCI
  content, so the registry is their natural home:
  `--export-cache type=registry,mode=max,ref=harbor.admin.siliconiq.com/minutemodem/minutemodem-native-base:buildcache`
  plus the matching `--import-cache`. Harbor tracks every intermediate layer as
  a first-class artifact, applies its own GC/retention, and it **reuses the CA +
  robot auth already wired for the image push — no new bucket or key**.
  `mode=max` stores *all* intermediate stage layers (not just final ones), which
  is what yields good reuse across rebuilds. (Harbor is Garage-backed, so the
  blobs still land in Garage — just managed through Harbor.)
- **App-tier *artifact* cache → Garage bucket `ci-artifact-cache`.** The
  `~/.hex`, `~/.mix`, Gradle, and cargo/zig `target` caches are plain tarballs,
  not OCI layers, so they don't belong in a registry. Content-hash keyed and
  restored so a wiped worker restores instead of recompiling.

### Pipeline graph

```
repo-ci-image ─▶ build-ci-image ─▶ ci-image (Harbor)
                                      │ passed
repo-native ───▶ build-native-base ─▶ native-base (Harbor)   [buildkit cache → Harbor :buildcache]
                                      │ passed
repo-dev/────▶ dev-prerelease  ─▶ APK ─▶ GitHub prerelease    [S3 artifact cache]
repo-release ▶ tagged-release  ─▶ APK ─▶ GitHub release       [S3 artifact cache]
```

## The load-bearing design decision (de-risk first)

Concourse mounts the app repo as a **fresh input** (`./repo`) *next to* the
image's baked content — it does not overlay onto the image's copy of the repo.
So native outputs that currently live *inside* the repo checkout
(`deps/hamlib_ex/android/hamlib/out`, `zig-out/`) can't simply be baked at their
in-repo path and expected to survive the Tier-2 checkout.

**Plan:** `build-native-base` bakes those outputs to **stable, out-of-repo
paths** (e.g. `/opt/mob-cache/hamlib-out`, `/opt/mob-cache/zig-out`), and the
Tier-2 `build-apk.sh` copies them into the checked-out repo's expected
(gitignored) locations before `mob.release`, then skips steps 5–6. The OTP
cache (step 3) already lives at `$HOME/.mob/cache`, which is image-native and
survives, so it needs no copy.

Open questions to resolve in the spike (Phase 1):

1. Does `mix mob.release` / Gradle consume pre-placed `zig-out/<abi>/*.o` without
   re-running `build_all`? (If Gradle re-invokes the NIF build, we point it at
   the baked objects or stub the build step.)
2. Are the baked NIF objects valid against a fresh `deps.get` at the same
   `mix.lock`? (They must be — same crate + dep versions. This is why
   `repo-native`'s trigger includes `mix.lock`.)
3. Do the `mob` / `mob_dev` quilt patches need to be applied before baking
   (Tier 1) or only in Tier 2? (The hamlib_ex OTP-staging patch affects step 6,
   so it must be applied in Tier 1; the vendor-USB patch affects the `.so` link
   at Gradle time, so Tier 2.)

Keep `mix deps.get` + patches in **Tier 2** (with a Garage hex cache) rather
than baking deps, so `native-base` isn't coupled to `mix.lock` churn.

Scope note: the APK ships `arm64-v8a` only (`mob.exs` `static_nifs` +
`android/app/build.gradle`), so Tier 1 bakes aarch64 only. Revisit if an
armeabi-v7a variant is ever shipped.

## Phased execution

Each phase is independently landable and has a verification gate. Phases 0–1
prove the mechanism cheaply before we commit to the pipeline rewrite.

### Phase 0 — cache backends
- Garage: create bucket `ci-artifact-cache` + a scoped key; store the key in
  OpenBao (`concourse/main/minutemodem/`) + reference in vars.
- buildkit's layer cache needs **no new storage** — it targets Harbor
  (`minutemodem-native-base:buildcache`) via the robot creds + CA we already have.
- **Verify:** `aws s3 ls` (or `mc`) against Garage for `ci-artifact-cache`, and
  confirm the robot can write a `:buildcache` tag into the Harbor project.

### Phase 1 — De-risk spike: bake + consume one native artifact
- Hand-build a throwaway `native-base` locally (or a scratch Concourse job) that
  bakes the OTP cache + hamlib + `zig-out` to `/opt/mob-cache`.
- A scratch app task: `image` = that base, copy baked outputs into the checkout,
  run `mob.release --android` + `assembleRelease` **without** steps 5–6.
- **Verify:** a signed APK builds, installs, and shows 303 rigs (same acceptance
  check we used to pin the 0-rigs bug) — proving baked NIFs are consumed.
- Resolve the three open questions above; write findings back into this doc.

### Phase 2 — `build-native-base` job (production)
- Add `ci/Dockerfile.native-base` (or a buildkit build script) that runs steps
  3/5/6 and stages outputs to `/opt/mob-cache` + the OTP cache.
- Add `repo-native` git resource, paths:
  `deps/hamlib_ex/android/hamlib/**`, `native/**`, `mix.lock`,
  `ci/patches/mob_dev/**`, `ci/tasks/build-native-base.sh`.
- Add `build-native-base` job: `passed: [build-ci-image]`, buildkit build with
  `--import-cache`/`--export-cache type=registry,mode=max` →
  `minutemodem-native-base:buildcache` in Harbor; image pushed as
  `minutemodem-native-base:latest`.
- **Verify:** image + `:buildcache` in Harbor; a second run is incremental
  (buildkit reports cache hits from the registry).

### Phase 3 — Slim the app tier
- Fork `build-apk.sh` → drop steps 5–6; add "restore baked outputs from
  `/opt/mob-cache`"; keep deps.get + patches + `mob.release` + Gradle.
- Point `dev-prerelease` / `tagged-release` at `image: native-base`,
  `passed: [build-native-base]`.
- **Verify:** an app-only commit produces the same APK as the monolith, faster.

### Phase 4 — App-tier S3 caches + cascade proof
- Add restore/save of `~/.hex`, `~/.mix`, Gradle, cargo/zig `target` to
  `ci-artifact-cache` (content-hash keys) around the app task.
- **Verify (speed):** second app build reuses caches (measure wall-clock).
- **Verify (resilience):** wipe/recreate the worker (the exact failure from
  July), re-run — the base image + S3 caches avoid a full native rebuild.
- **Verify (cascade):** bump the Hamlib version → `build-native-base` fires →
  app build picks up the new base via `passed:`.

### Phase 5 — Docs + community write-up
- Fold the final flow into `ci/README.md`.
- Optional: a public write-up of the tiered pattern (native-base + buildkit S3
  cache) for Mob-on-Android CI.

## Risks & mitigations

- **Baked NIFs not consumed by Gradle** → the whole split. Mitigated by the
  Phase-1 spike before any pipeline change; fallback is to keep step 6 in Tier 2
  but still lift steps 3 & 5 (still a large win).
- **Stale baked artifacts** (native change without a `repo-native` trigger) →
  cover every native input in the path filter; when unsure, a native input is
  cheap to add to the filter.
- **Caches as a CI dependency** → both the Harbor buildkit cache and the Garage
  artifact cache are best-effort: a cache miss must degrade to a slower build,
  never a failed one. All import/restore steps are guarded and re-populate on
  success.
- **Single worker** → task caches are worker-local; the S3 caches (Phase 4) are
  the durable layer that makes a worker reset survivable.

## Definition of done

- App-only commit: no Hamlib cross-build, no `build_all`, no OTP download; APK in
  a few minutes.
- Native change: `build-native-base` rebuilds (incrementally via Garage cache)
  and cascades to the app build.
- Worker reset: recovers without redoing the heavy native work.
- Nothing in the hot path depends on docker.io except OS/base layers.
