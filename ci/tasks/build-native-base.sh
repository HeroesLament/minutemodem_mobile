#!/usr/bin/env sh
# Build minutemodem-native-base with buildkit and push it to Harbor, using a
# Harbor registry layer cache so rebuilds are incremental (and survive a worker
# reset — the reason this whole tier exists).
# ==========================================================================
# Same buildkitd/CA/auth setup as build-ci-image.sh; differences:
#   * builds ci/Dockerfile.native-base against the whole repo (context),
#   * pulls its FROM (ci-image) from Harbor with the same creds/CA,
#   * imports/exports a registry cache at <image>:buildcache (mode=max).
#
# Inputs (task params):
#   IMAGE_REF           harbor.host/proj/minutemodem-native-base:tag
#   CI_IMAGE            the ci-image ref to FROM (build-arg)
#   HARBOR_ROBOT_USER   registry username (robot$…)
#   HARBOR_ROBOT_TOKEN  registry password/secret
#   HARBOR_CA           PEM of the CA that signed Harbor's TLS cert
# Input dir: repo-native/ (git checkout; Dockerfile at ci/Dockerfile.native-base).
set -eu

: "${IMAGE_REF:?missing IMAGE_REF}"
: "${CI_IMAGE:?missing CI_IMAGE}"
: "${HARBOR_ROBOT_USER:?missing HARBOR_ROBOT_USER}"
: "${HARBOR_ROBOT_TOKEN:?missing HARBOR_ROBOT_TOKEN}"
: "${HARBOR_CA:?missing HARBOR_CA}"

HARBOR_HOST="${IMAGE_REF%%/*}"
CACHE_REF="${IMAGE_REF%:*}:buildcache"

# --- trust Harbor's private CA (registry data-plane) ------------------------
mkdir -p /etc/buildkit
printf '%s\n' "$HARBOR_CA" > /etc/buildkit/harbor-ca.pem
cat > /etc/buildkit/buildkitd.toml <<EOF
[registry."${HARBOR_HOST}"]
  ca = ["/etc/buildkit/harbor-ca.pem"]
EOF

# buildkitd's OAuth token fetch uses Go's system trust, not the registry ca=;
# build a combined bundle and point SSL_CERT_FILE at it (see build-ci-image.sh).
: > /tmp/ca-bundle.pem
for sysca in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -f "$sysca" ]; then cat "$sysca" >> /tmp/ca-bundle.pem; break; fi
done
cat /etc/buildkit/harbor-ca.pem >> /tmp/ca-bundle.pem
export SSL_CERT_FILE=/tmp/ca-bundle.pem

# --- registry auth (pull FROM + push image + cache) -------------------------
export DOCKER_CONFIG=/root/.docker
mkdir -p "$DOCKER_CONFIG"
AUTH=$(printf '%s:%s' "$HARBOR_ROBOT_USER" "$HARBOR_ROBOT_TOKEN" | base64 | tr -d '\n')
cat > "$DOCKER_CONFIG/config.json" <<EOF
{"auths":{"${HARBOR_HOST}":{"auth":"${AUTH}"}}}
EOF

# --- start buildkitd (host net for fast pulls/downloads + persistent cache) --
mkdir -p /run/buildkit
BK_ROOT="$(pwd)/buildkit-cache"
mkdir -p "$BK_ROOT"
export BUILDKIT_HOST=unix:///run/buildkit/buildkitd.sock
buildkitd --config /etc/buildkit/buildkitd.toml --addr "$BUILDKIT_HOST" \
  --oci-worker-net=host --root "$BK_ROOT" \
  >/tmp/buildkitd.log 2>&1 &

i=0
while [ "$i" -lt 60 ]; do
  if buildctl debug workers >/dev/null 2>&1; then break; fi
  i=$((i + 1)); sleep 1
done
buildctl debug workers >/dev/null 2>&1 || { echo "!! buildkitd never became ready"; cat /tmp/buildkitd.log; exit 1; }

# --- build + push -----------------------------------------------------------
# NOTE: no registry (mode=max) layer cache. The bake RUN layer keys off the
# COPY of the repo, so it invalidates on every commit that touches native-base's
# inputs — which is exactly what triggers this job. So the registry cache almost
# never hit the expensive step, while importing its ~3 GB of mode=max layers up
# front crawled and filled the worker disk (a build hung 34 min on --import-cache
# alone). buildkit's local --root cache (the buildkit-cache task cache below)
# still speeds the FROM/base layers across runs on the same worker.
echo "== building ${IMAGE_REF} (FROM ${CI_IMAGE}) =="
buildctl build \
  --frontend dockerfile.v0 \
  --local context=repo-native \
  --local dockerfile=repo-native/ci \
  --opt filename=Dockerfile.native-base \
  --opt build-arg:CI_IMAGE="${CI_IMAGE}" \
  --output "type=image,name=${IMAGE_REF},push=true"

echo "== pushed ${IMAGE_REF} =="
