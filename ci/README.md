# MinuteModem — CI/CD (self-hosted Concourse)

An **automatically-triggered** Concourse pipeline that builds the signed release
APK (and AAB) in a reproducible container and publishes it to GitHub Releases
with the `gh` CLI. Everything runs against the in-house homelab: images in
**Harbor** (HTTPS via the SiliconIQ private CA, **Garage** S3 backend), secrets
in **OpenBao**. The only thing pulled from docker.io is the `debian:trixie-slim`
base layer buildkit fetches.

Nothing here ever puts the signing keystore or a token into version control. The
keystore lives only as a base64 value in OpenBao; the pipeline decodes it into a
tmpfile at build time and shreds it on exit.

> **Not manual-only anymore.** Earlier this was a single hand-triggered job.
> It's now a four-job pipeline that fires on git activity: app commits to `dev`
> cut prereleases, `v*` tags cut releases, and the two build-image tiers rebuild
> themselves when their inputs change. You can still trigger any job by hand.

## At a glance

| Job | Fires when | Produces |
|-----|-----------|----------|
| `build-ci-image` | `ci/Dockerfile`, `.tool-versions`, `ci/patches/**`, or `ci/tasks/build-ci-image.sh` changes on `dev` | `minutemodem-ci` image → Harbor |
| `build-native-base` | native inputs change (see `repo-native` paths) **or** a new `ci-image` | `minutemodem-native-base` image → Harbor |
| `dev-prerelease` | any commit to `dev` | APK/AAB → GitHub **prerelease** `build-<UTC>-<sha>` |
| `tagged-release` | a `v*` tag is pushed | APK/AAB → GitHub **Release** (named for the tag, marked latest) |

The two APK jobs share `serial_groups: [build]`, so only one runs at a time on
the single `ccis1` worker.

## The three tiers

Each tier is rebuilt only on its own inputs, so an app-only commit skips the
slow native work entirely (see `MULTIPART-PLAN.md` for the design and
`MOB-TIERED-CI.md` for the pattern write-up):

    build-ci-image ───► ci-image           OS + asdf toolchain (Erlang/Elixir/zig)
                            │                + Android SDK/NDK + gh. Rarely rebuilds.
                            ▼
    build-native-base ─► native-base       FROM ci-image + cross-built Hamlib + OTP
                            │                runtime + prebuilt libminutemodem_mobile.so
                            ▼                baked to /opt/mob-bake. Rebuilds on native change.
    [repo] ─► dev-prerelease / tagged-release ─► APK ─► GitHub Release
                   ▲ image: native-base — build-apk.sh restores the baked .so and
                   │ skips the Hamlib cross-build + build_all. keystore_*/gh_token
                   │ from OpenBao; Gradle/_build cache in Garage S3.

A native change (`native/**`, `mix.lock`, `.tool-versions`, the mob/mob_dev
patches, the native-base Dockerfile/scripts) fires `build-native-base`; the app
tier then cascades onto the new `native-base` image via `trigger: true`.

> **Why the image jobs push straight to Harbor with buildkit (not a Concourse
> `put`):** the registry-image versions aren't outputs of the build job, so
> downstream jobs can't use `passed:`. The cascade rides on
> `get: <upstream-image>` with `trigger: true` instead.

## Versioning

The `v*` tag (or commit position for dev builds) drives the **APK's own**
`versionName`/`versionCode`, not just the artifact filename. `build-apk.sh`
resolves the version *before* the Gradle build and feeds it through
`android/local.properties`; `android/app/build.gradle` reads
`app.version_name`/`app.version_code` (with env + static fallbacks so a plain
local `gradlew` still builds).

| Flow (`VERSION_MODE`) | `versionName` | `versionCode` | Release name |
|---|---|---|---|
| `tag` (tagged-release) | tag without the `v` (e.g. `0.1.1`) | `git rev-list --count HEAD` | `v0.1.1` |
| `timestamp` (dev-prerelease) | `git describe --match 'v*'` (e.g. `0.1.1-3-gabc123`) or sha | `git rev-list --count HEAD` | `build-<UTC>-<sha>` |

`versionCode` is the commit count because Android refuses to install an update
whose code isn't strictly higher than the installed one; commit count is
monotonic across both flows.

## Layout

    ci/
      Dockerfile               ci-image (toolchain + Android SDK/NDK + gh)
      Dockerfile.native-base   native-base = ci-image + baked Hamlib/OTP/.so
      pipeline.yml             resources + the four jobs above
      vars.example.yml         non-secret vars template -> copy to ci/vars.yml
      MULTIPART-PLAN.md        the tiered-build design + status
      MOB-TIERED-CI.md         community write-up of the Mob-on-Android pattern
      patches/                 quilt patch stacks for mob / mob_dev
      tasks/
        build-ci-image.sh      buildkit -> Harbor (ci-image)
        native-base-bake.sh    deps + Hamlib cross-build + build_all; stages jniLibs/*.so
        build-native-base.sh   buildkit -> Harbor (native-base)
        build-apk.yml/.sh      build signed APK/AAB (auto-detects native-base; sets version)
        s3-cache.sh            best-effort Garage S3 cache (Gradle + _build)
        publish-release.yml/.sh  gh release create + upload (+ prune for prereleases)

## Toolchain pins (`.tool-versions`)

    erlang 29.0
    elixir 1.19.5-otp-28
    java   temurin-17.0.18
    zig    0.16.0

> **The Elixir pin is load-bearing.** It must match the version baked into Mob's
> Android OTP runtime bundle (Mob 0.7.5 → Elixir 1.19.5). A newer host Elixir
> skews codegen — e.g. Elixir 1.20 expands `in` to `Enum.__in__/2`, which the
> 1.19.5 device runtime doesn't export, so `Ecto.Migrator` crashes on boot with
> `{error, undef}` and the app shows a black screen. Debug deploys hide it (same
> host Elixir compiles *and* runs). Keep it at 1.19.x.

## One-time setup

### 1. Images (self-hosted in Harbor)

The `ci-image` and `native-base` images live in the in-house Harbor registry
(`harbor.admin.siliconiq.com/minutemodem/…`) and are **built by Concourse
itself**. The first `build-ci-image` run is slow — it compiles Erlang from
source and pulls the Android NDK; everything after reuses buildkit's cache.

Bootstrap once so the APK jobs have an image to pull (or just let the trigger
fire on the first matching commit):

    fly -t ccis1 trigger-job -j minutemodem/build-ci-image --watch
    fly -t ccis1 trigger-job -j minutemodem/build-native-base --watch

Harbor also holds a mirror of the buildkit image the image-build jobs run in
(`minutemodem/oci-build-task`).

### 2. Store secrets in OpenBao

OpenBao is Vault-API compatible, so Concourse's built-in Vault credential
manager talks to it unchanged. Put secrets under
`concourse/<team>/<pipeline>/<name>` (default team `main`):

    # release keystore, base64 (single line, no wrapping)
    base64 -w0 upload-keystore.jks > /tmp/ks.b64
    bao kv put concourse/main/minutemodem/keystore_b64            value=@/tmp/ks.b64
    shred -u /tmp/ks.b64
    bao kv put concourse/main/minutemodem/keystore_store_password value='********'
    bao kv put concourse/main/minutemodem/keystore_key_alias      value='upload'
    bao kv put concourse/main/minutemodem/keystore_key_password   value='********'

    # GitHub token — issued from the HeroesLament account so the release author
    # matches the project's git identity (scope: classic 'repo', or fine-grained
    # Contents: read/write on this repo).
    bao kv put concourse/main/minutemodem/gh_token                value='ghp_xxx'

    # Harbor robot account (project 'minutemodem', pull+push) for registry-image:
    bao kv put concourse/main/minutemodem/harbor_robot_user       value='robot$minutemodem+ci'
    bao kv put concourse/main/minutemodem/harbor_robot_token      value='<robot-secret>'

    # Garage S3 key for the app-tier build cache (bucket ci-artifact-cache):
    bao kv put concourse/main/minutemodem/garage_cache_key_id     value='<key-id>'
    bao kv put concourse/main/minutemodem/garage_cache_key_secret value='<secret>'

The Root CA that signs Harbor's TLS cert is **not** secret — it lives in
`ci/vars.yml` as `harbor_ca:` (a PEM block scalar) so the registry-image
resources can verify Harbor over HTTPS.

### 3. Point the Concourse web node at OpenBao

Set on the `web` node and restart it (this lab uses a client token; approle is
recommended for production):

    CONCOURSE_VAULT_URL=https://obao.admin.siliconiq.com:8200
    CONCOURSE_VAULT_PATH_PREFIX=/concourse
    CONCOURSE_VAULT_CA_CERT=/secrets/obao-ca.pem
    CONCOURSE_VAULT_CLIENT_TOKEN=<token>     # or approle: CONCOURSE_VAULT_AUTH_BACKEND=approle

### 4. Non-secret vars + set the pipeline

    cp ci/vars.example.yml ci/vars.yml       # ci/vars.yml is gitignored
    $EDITOR ci/vars.yml                      # git_uri, branches, *_repo, gh_repo, garage_endpoint, harbor_ca
    fly -t ccis1 set-pipeline -p minutemodem -c ci/pipeline.yml -l ci/vars.yml
    fly -t ccis1 unpause-pipeline -p minutemodem

## Cutting builds & releases

**Dev prerelease — automatic.** Every push to `dev` triggers `dev-prerelease`:
it builds the APK on the warm `native-base`, publishes a GitHub *prerelease*
tagged `build-<UTC>-<sha>`, and prunes older prereleases (testers just grab "the
latest prerelease"). Nothing to run by hand.

**Tagged release.** The release flow is **merge `dev` → `main` (`--no-ff`), then
tag on `main`**:

    git checkout main
    git merge --no-ff dev -m "release: v0.1.1"
    git tag -a v0.1.1 -m "MinuteModem v0.1.1"
    git push origin main
    git push origin v0.1.1        # this is what fires tagged-release

`repo-release` detects the tag (`tag_filter: v[0-9]*`, tag-only — see the note
below), `tagged-release` builds it with `VERSION_MODE=tag`, and publishes a full
GitHub Release named for the tag, marked latest, with the `.apk`/`.aab`
attached. Prereleases are left untouched.

> **Why `repo-release` has no `branch:`.** The git resource does a single-branch
> fetch when a branch is pinned and never fetches tag refs — so `branch: main`
> **plus** `tag_filter` detects nothing. Tag-only detection is the canonical
> trigger. Since the release flow only ever puts `v*` tags on `main`, this is the
> same guard in practice.

**Manual trigger** (any job) is still available:

    fly -t ccis1 trigger-job -j minutemodem/dev-prerelease --watch

or hit **+** on the job in the web UI.

## Notes / knobs

- **Stable vs prerelease** is the job, not a flag: `dev-prerelease` sets
  `PRERELEASE=true` + prune; `tagged-release` sets `PRERELEASE=false`, no prune
  (see `tasks/publish-release.sh`).
- **App-tier cache** (`s3-cache.sh`): Gradle + `_build` tarballs in Garage
  (`ci-artifact-cache`), keyed `dev`/`release`. Entirely best-effort — missing
  creds/endpoint just skip caching, never fail the build.
- **Network**: the build container pulls Hex deps, the Mob OTP tarball, and
  Gradle deps at run time, so it needs outbound internet.
- **google-services.json**: the repo's placeholder is enough to build; FCM push
  won't work until a real one is dropped in. No secret needed for CI.
- **Worker wedge**: after an unclean abort the privileged worker's containerd can
  crash-loop and jobs error with `no workers satisfying: …`. Recover with
  `fly -t ccis1 prune-worker -w <name>` then recreate the worker container
  (`podman-compose … up -d --force-recreate --no-deps worker`).
