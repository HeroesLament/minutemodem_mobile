#!/usr/bin/env sh
# Build the MinuteModem CI image with buildkit and push it STRAIGHT to Harbor.
# ===========================================================================
# We deliberately do NOT use oci-build-task's default flow (export the built
# image to a local image.tar, then have a registry-image `put` re-upload it).
# This image is multi-GB (Android SDK/NDK + Erlang-from-source), and that flow
# materialises the whole thing as a local tarball on the Concourse volume, then
# reads it back to push — double the I/O. On a modest single worker the final
# tarball export reliably trips `context deadline exceeded`.
#
# Instead buildkit streams layers directly to Harbor with `--output push=true`,
# so nothing large is written to the worker's disk.
#
# Inputs (Concourse task params):
#   IMAGE_REF           harbor.host/proj/name:tag to build+push
#   HARBOR_ROBOT_USER   registry username (robot$… account)
#   HARBOR_ROBOT_TOKEN  registry password/secret
#   HARBOR_CA           PEM of the CA that signed Harbor's TLS cert
# Input dir: repo-ci-image/ (the git checkout; Dockerfile at ci/Dockerfile).
set -eu

: "${IMAGE_REF:?missing IMAGE_REF}"
: "${HARBOR_ROBOT_USER:?missing HARBOR_ROBOT_USER}"
: "${HARBOR_ROBOT_TOKEN:?missing HARBOR_ROBOT_TOKEN}"
: "${HARBOR_CA:?missing HARBOR_CA}"

# Registry host = everything before the first '/' in the image ref.
HARBOR_HOST="${IMAGE_REF%%/*}"

# --- trust Harbor's private CA in buildkitd ---------------------------------
mkdir -p /etc/buildkit
printf '%s\n' "$HARBOR_CA" > /etc/buildkit/harbor-ca.pem
cat > /etc/buildkit/buildkitd.toml <<EOF
[registry."${HARBOR_HOST}"]
  ca = ["/etc/buildkit/harbor-ca.pem"]
EOF

# --- registry auth for the push (buildctl reads DOCKER_CONFIG/config.json) ---
export DOCKER_CONFIG=/root/.docker
mkdir -p "$DOCKER_CONFIG"
AUTH=$(printf '%s:%s' "$HARBOR_ROBOT_USER" "$HARBOR_ROBOT_TOKEN" | base64 | tr -d '\n')
cat > "$DOCKER_CONFIG/config.json" <<EOF
{"auths":{"${HARBOR_HOST}":{"auth":"${AUTH}"}}}
EOF

# --- start buildkitd + wait for it ------------------------------------------
mkdir -p /run/buildkit
export BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock
buildkitd --config /etc/buildkit/buildkitd.toml --addr "$BUILDKIT_HOST" \
  >/tmp/buildkitd.log 2>&1 &

i=0
while [ "$i" -lt 60 ]; do
  if buildctl debug workers >/dev/null 2>&1; then break; fi
  i=$((i + 1)); sleep 1
done
if ! buildctl debug workers >/dev/null 2>&1; then
  echo "!! buildkitd never became ready"; cat /tmp/buildkitd.log; exit 1
fi

# --- build from ci/Dockerfile and push straight to Harbor -------------------
# The Dockerfile is self-contained (versions baked as ARGs, no repo files
# COPY'd), so the build context is just the ci/ dir.
echo "== building + pushing ${IMAGE_REF} =="
buildctl build \
  --frontend dockerfile.v0 \
  --local context=repo-ci-image/ci \
  --local dockerfile=repo-ci-image/ci \
  --output "type=image,name=${IMAGE_REF},push=true"

echo "== pushed ${IMAGE_REF} =="
