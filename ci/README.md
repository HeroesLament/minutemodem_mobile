# MinuteModem — Concourse APK build & GitHub release

A manual-trigger Concourse job that builds the signed release APK (and AAB) in a
reproducible container and publishes it to GitHub Releases with the `gh` CLI.

Nothing here ever puts the signing keystore or a token into version control. The
keystore lives only as a base64 value in OpenBao; the pipeline decodes it into a
tmpfile at build time and shreds it on exit.

## Layout

    ci/
      Dockerfile               ci-image (toolchain + Android SDK/NDK + gh)
      Dockerfile.native-base   native-base = ci-image + baked Hamlib/OTP/.so
      pipeline.yml             build-ci-image, build-native-base, dev/tagged jobs
      vars.example.yml         non-secret vars template -> copy to ci/vars.yml
      MULTIPART-PLAN.md        the tiered-build plan + status
      MOB-TIERED-CI.md         community write-up of the pattern
      tasks/
        build-ci-image.sh      buildkit -> Harbor (ci-image)
        native-base-bake.sh    steps 1-6 + stage jniLibs/*.so (runs in native-base)
        build-native-base.sh   buildkit -> Harbor (native-base) + registry cache
        build-apk.yml/.sh      build the signed APK/AAB (auto-detects native-base)
        s3-cache.sh            best-effort Garage S3 cache (Gradle + _build)
        publish-release.yml/.sh  gh release create + upload

## How it fits together

Three tiers, each rebuilt only on its own inputs (see `MULTIPART-PLAN.md` for
the full design, `MOB-TIERED-CI.md` for the pattern write-up):

    build-ci-image ─► ci-image            (Erlang/Elixir/zig + Android SDK/NDK)
                          │
    build-native-base ─► native-base      (+ cross-built Hamlib + OTP + prebuilt .so)
                          │
    [repo] ─► dev-prerelease / tagged-release ─► APK ─► GitHub Release
                   ▲ image: native-base — build-apk.sh restores the baked .so and
                   │ skips the Hamlib cross-build + build_all.
                   │ keystore_*/gh_token from OpenBao; Gradle/_build cache in Garage S3.

A native change (`native/**`, `mix.lock`, `.tool-versions`, the mob_dev patch)
fires `build-native-base`; an app-only commit runs just the app tier on the warm
`native-base`.

## One-time setup

### 1. The CI image (self-hosted in Harbor)

The CI build image lives in the in-house Harbor registry
(`harbor.admin.siliconiq.com/minutemodem/minutemodem-ci`) and is **built by
Concourse itself** — the `build-ci-image` job runs buildkit (`oci-build-task`)
over `ci/Dockerfile` and pushes the result to Harbor. It fires automatically
whenever `ci/Dockerfile`, `.tool-versions`, or `ci/patches/**` change, so you
never hand-build it again.

The first build is slow — it compiles Erlang from source and pulls the Android
NDK. Everything after that reuses buildkit's cache.

Bootstrap (once, so the APK jobs have an image to pull before the first
`build-ci-image` run — or just trigger `build-ci-image` first):

    # Seed Harbor from an existing image, or let build-ci-image populate it.
    fly -t home trigger-job -j minutemodem/build-ci-image --watch

Harbor also holds a mirror of the buildkit image the job runs in
(`minutemodem/oci-build-task`). The only thing still pulled from docker.io is
the `FROM debian:trixie-slim` base layer that buildkit fetches.

> The Elixir pin (1.19.5) must match the device runtime. A newer host Elixir
> makes Ecto emit `Enum.__in__/2`, which the on-device 1.19.5 runtime doesn't
> export → boot crash / black screen. This is why the image reproduces the pin
> rather than using "latest".

### 2. Store secrets in OpenBao

OpenBao is Vault-API compatible, so Concourse's built-in Vault credential
manager talks to it unchanged. Put the secrets under the path Concourse looks up
for this team/pipeline (`concourse/<team>/<pipeline>/<name>`, default team
`main`):

    # release keystore, base64-encoded (single line, no wrapping)
    base64 -w0 upload-keystore.jks > /tmp/ks.b64
    bao kv put concourse/main/minutemodem/keystore_b64            value=@/tmp/ks.b64
    shred -u /tmp/ks.b64

    bao kv put concourse/main/minutemodem/keystore_store_password value='********'
    bao kv put concourse/main/minutemodem/keystore_key_alias      value='upload'
    bao kv put concourse/main/minutemodem/keystore_key_password   value='********'

    # GitHub token — issued from the HeroesLament account so the release author
    # matches the project's git identity. Scope: classic 'repo', or fine-grained
    # with Contents: read/write on this repo only.
    bao kv put concourse/main/minutemodem/gh_token               value='ghp_xxx'

    # Only if the repo is private — SSH deploy key for the git resource:
    bao kv put concourse/main/minutemodem/git_ssh_key            value=@/path/to/deploy_key

    # Harbor robot account (project 'minutemodem', pull+push) for the
    # registry-image resources. Create it in Harbor, then:
    bao kv put concourse/main/minutemodem/harbor_robot_user      value='robot$minutemodem+ci'
    bao kv put concourse/main/minutemodem/harbor_robot_token     value='<robot-secret>'

The Root CA that signs Harbor's TLS cert is **not** secret — it lives in
`ci/vars.yml` as `harbor_ca:` (a PEM block scalar) so the registry-image
resource can verify Harbor over HTTPS.

If your OpenBao KV mount name isn't `concourse`, point Concourse's
`CONCOURSE_VAULT_PATH_PREFIX` at whatever you used.

### 3. Point Concourse's web node at OpenBao

Set these on the `web` node (env / BOSH / compose) and restart it:

    CONCOURSE_VAULT_URL=https://openbao.your.lan:8200
    CONCOURSE_VAULT_PATH_PREFIX=/concourse
    CONCOURSE_VAULT_AUTH_BACKEND=approle        # recommended over a raw token
    CONCOURSE_VAULT_AUTH_PARAM=role_id:<id>,secret_id:<id>
    # (or, quick-and-dirty:) CONCOURSE_VAULT_CLIENT_TOKEN=<token>
    # if OpenBao uses a private CA:
    CONCOURSE_VAULT_CA_CERT=/path/to/openbao-ca.pem

Verify resolution after restart:

    fly -t home get-pipeline -p minutemodem   # (once set) — vars stay as ((..)) unresolved is normal here
    # real check: trigger the job and watch it succeed at the build step.

### 4. Set non-secret vars

    cp ci/vars.example.yml ci/vars.yml     # ci/vars.yml is gitignored
    $EDITOR ci/vars.yml                    # git_uri, git_branch, ci_image_repo, gh_repo

### 5. Set the pipeline

    fly -t home set-pipeline -p minutemodem -c ci/pipeline.yml -l ci/vars.yml
    fly -t home unpause-pipeline -p minutemodem

## Running a build

Manual only:

    fly -t home trigger-job -j minutemodem/build-and-release --watch

or hit **+** on the job in the web UI. On success a new **pre-release** appears
at `https://github.com/<gh_repo>/releases`, tagged `build-<UTC>-<shortsha>`, with
the `.apk` (and `.aab`) attached.

## Notes / knobs

- **Artifact naming**: `minutemodem-build-<UTC>-<shortsha>.apk`. Edit
  `tasks/build-apk.sh` (the `VER=` line) to change the scheme — e.g. read
  `versionName` from `android/app/build.gradle` instead.
- **Stable vs pre-release**: drop `--prerelease` in `tasks/publish-release.sh`
  to cut normal releases.
- **Network**: the build container pulls Hex deps, the Mob OTP tarball, and
  Gradle deps at run time, so it needs outbound internet.
- **Switch to tag-driven** later: add a second git resource filtered on
  `tag_filter: 'v*'` with `trigger: true`, and derive `VER` from the tag.
- **google-services.json**: the repo's placeholder is enough to build; FCM push
  just won't work until a real one is dropped in. No secret needed for CI.
