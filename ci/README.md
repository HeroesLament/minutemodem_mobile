# MinuteModem — Concourse APK build & GitHub release

A manual-trigger Concourse job that builds the signed release APK (and AAB) in a
reproducible container and publishes it to GitHub Releases with the `gh` CLI.

Nothing here ever puts the signing keystore or a token into version control. The
keystore lives only as a base64 value in OpenBao; the pipeline decodes it into a
tmpfile at build time and shreds it on exit.

## Layout

    ci/
      Dockerfile               CI build image (toolchain + Android SDK + gh)
      pipeline.yml             the manual build-and-release job
      vars.example.yml         non-secret vars template -> copy to ci/vars.yml
      tasks/
        build-apk.yml/.sh      build the signed APK/AAB, stage in artifacts/
        publish-release.yml/.sh  gh release create + upload

## How it fits together

    [git repo] ─┐
                ├─► build-apk  ─► artifacts/{apk,aab,version,commit} ─► publish-release ─► GitHub Release
    [ci-image] ─┘        ▲                                                     ▲
                         │ keystore_* from OpenBao                            │ gh_token from OpenBao

## One-time setup

### 1. Build & push the CI image

Build context is the repo root (so the image can bake in `.tool-versions`):

    docker build -t docker.io/YOURUSER/minutemodem-ci:latest -f ci/Dockerfile .
    docker push  docker.io/YOURUSER/minutemodem-ci:latest

The first build is slow — it compiles Erlang 29.0 from source and pulls the
Android NDK. Rebuild it only when `.tool-versions` or the SDK/NDK pins change.

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
