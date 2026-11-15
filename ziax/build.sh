#!/bin/bash
# Builds IMAGE (source.env): the upstream Quay image BASE_IMAGE with the files that FORK_COMMIT, a commit of this
# repository, changes since BASE_COMMIT written over it (Containerfile). The result is upstream's own build plus our
# changes. Nothing upstream compiled or bundled (the web UI, config-tool, Python wheels) is rebuilt, so only changed
# Python modules and Jinja templates can be carried this way. This repository's own tooling, ziax/ and .teamcity/, is
# not part of the image.
#
# FORK_COMMIT is the commit to build: on TeamCity the revision the build checked out, locally HEAD. Only committed
# changes are built.
#
# PUSH=false, the default, builds and smoke-tests the image and pushes nothing. PUSH=true also publishes it as
# IMAGE:<BASE_VERSION>-<first 12 hex of FORK_COMMIT>, once: a tag that already exists is never pushed over, because
# man1-prod1's Quay Subscription pins the digest the tag was first published with, and quay.io garbage-collects a
# digest that no tag names.
#
# Needs git, python3 and docker. CONTAINER_ENGINE=podman builds and smoke-tests too, but only docker publishes: the
# image goes to the registry from the Docker daemon, through skopeo (pinned, run as a container) converting it to a
# single OCI manifest. Publishing needs a quay.io login in REGISTRY_AUTH_FILE.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=images/quay/source.env
. "$HERE/source.env"
PUSH="${PUSH:-false}"
ENGINE="${CONTAINER_ENGINE:-docker}"

fail() {
  echo "$*" >&2
  exit 1
}
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
FORK_COMMIT="${FORK_COMMIT:-$(git -C "$REPO" rev-parse HEAD)}"
for name in BASE_IMAGE BASE_VERSION BASE_COMMIT SOURCE_URL FORK_COMMIT IMAGE; do
  [ -n "${!name:-}" ] || fail "source.env does not set $name"
done
[[ "$BASE_COMMIT" =~ ^[0-9a-f]{40}$ && "$FORK_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "BASE_COMMIT and FORK_COMMIT must be full commit hashes"
[[ "$BASE_IMAGE" =~ ^[^:@]+@sha256:[0-9a-f]{64}$ ]] || fail "BASE_IMAGE must be pinned by digest alone"

TAG="$BASE_VERSION-${FORK_COMMIT:0:12}"
# A name of this build's own in the Docker daemon the agents share, removed when the build ends.
LOCAL="localhost/ziax-quay-build:$(date +%s)-$$"
WORK="$(mktemp -d)"
cleanup() {
  "$ENGINE" image rm "$LOCAL" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. The commit, which must be built on BASE_COMMIT. A checkout without BASE_COMMIT is too shallow to tell.
for commit in "$BASE_COMMIT" "$FORK_COMMIT"; do
  git -C "$REPO" cat-file -e "$commit^{commit}" 2>/dev/null ||
    fail "$commit is not in this checkout: build.sh needs this branch's history back to BASE_COMMIT"
done
git -C "$REPO" merge-base --is-ancestor "$BASE_COMMIT" "$FORK_COMMIT" ||
  fail "FORK_COMMIT $FORK_COMMIT is not built on BASE_COMMIT $BASE_COMMIT"
if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo "The checkout has uncommitted changes. They are not built: the image takes $FORK_COMMIT's files"
fi

# 2. What it changes. This repository's tooling and tests stay out of the image. Anything else but a changed Python
#    module or Jinja template needs a full build of upstream's Containerfile, which this is not.
files=()
refused=()
while IFS=$'\t' read -r status path; do
  case "$path" in
    ziax/* | .teamcity/* | test/* | */test/* | */conftest.py | *_test.py) continue ;;
  esac
  case "$status:$path" in
    *:config-tool/* | *:web/* | *:static/*) refused+=("$status $path") ;;
    M:*.py | M:*.jnj) files+=("$path") ;;
    *) refused+=("$status $path") ;;
  esac
done < <(git -C "$REPO" diff --name-status --no-renames "$BASE_COMMIT" "$FORK_COMMIT")
if [ "${#refused[@]}" -gt 0 ]; then
  echo "Only changed Python modules and Jinja templates can be written over the upstream image. Not these:" >&2
  printf '  %s\n' "${refused[@]}" >&2
  exit 1
fi
[ "${#files[@]}" -gt 0 ] || fail "FORK_COMMIT changes nothing the image runs"
echo "$FORK_COMMIT changes, since $BASE_COMMIT:"
printf '  %s\n' "${files[@]}"
mkdir -p "$WORK/context/overlay"
git -C "$REPO" archive "$FORK_COMMIT" -- "${files[@]}" | tar -x -C "$WORK/context/overlay"

# 3. BASE_IMAGE must hold BASE_COMMIT's version of each of those files, or the changes would be written over code the
#    image does not run, undoing whatever it has in their place.
"$ENGINE" pull -q "$BASE_IMAGE" >/dev/null
expected="$(for f in "${files[@]}"; do
  printf '%s  %s\n' "$(git -C "$REPO" show "$BASE_COMMIT:$f" | sha256sum | cut -d' ' -f1)" "$f"
done)"
actual="$("$ENGINE" run --rm --entrypoint /bin/sh "$BASE_IMAGE" \
  -c 'cd /quay-registry && sha256sum "$@"' sh "${files[@]}")"
if [ "$expected" != "$actual" ]; then
  echo "BASE_IMAGE does not hold BASE_COMMIT's version of these files. In git:" >&2
  echo "$expected" >&2
  echo "In the image:" >&2
  echo "$actual" >&2
  exit 1
fi

# 4. The image.
progress=()
[ "$ENGINE" = docker ] && progress=(--progress=plain)
"$ENGINE" build "${progress[@]}" \
  --file "$HERE/Containerfile" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --label "org.opencontainers.image.source=$SOURCE_URL" \
  --label "org.opencontainers.image.revision=$FORK_COMMIT" \
  --label "org.opencontainers.image.version=$TAG" \
  --label "org.opencontainers.image.base.name=$BASE_IMAGE" \
  --label "ltd.ziax.quay.base-commit=$BASE_COMMIT" \
  --tag "$LOCAL" \
  "$WORK/context"

# 5. Smoke test. render writes a config.yaml of $1, renders Quay's nginx configuration from it with the image's own
#    conf/init/nginx_conf_create.py, as the image does when it boots, checks the result with nginx -t, and prints the
#    blob location. It runs as OpenShift runs Quay: an arbitrary user in group 0, so a file or directory that lost its
#    group-write bit fails it. SMOKE_UID overrides the user for rootless podman, which maps too few IDs for
#    OpenShift's.
render() {
  "$ENGINE" run --rm --user "${SMOKE_UID:-1000690000}:0" --entrypoint /bin/bash "$LOCAL" -c '
    set -euo pipefail
    cd /quay-registry
    printf "%s\n" "$1" > conf/stack/config.yaml
    python conf/init/nginx_conf_create.py
    nginx -t -q -c /quay-registry/conf/nginx/nginx.conf
    sed -n "/blobs\/ {/,/^}/p" conf/nginx/server-base.conf' render "$1"
}
with="$(render 'BLOB_UPLOAD_CLIENT_BODY_BUFFER_SIZE: 4m')"
grep -q -x '    client_body_buffer_size 4m;' <<<"$with" ||
  fail "$(printf 'BLOB_UPLOAD_CLIENT_BODY_BUFFER_SIZE did not reach the blob location:\n%s' "$with")"
without="$(render 'SERVER_HOSTNAME: smoke.invalid')"
if grep -q client_body_buffer_size <<<"$without"; then
  fail "client_body_buffer_size is rendered although config.yaml does not set BLOB_UPLOAD_CLIENT_BODY_BUFFER_SIZE"
fi
echo "Smoke test passed: nginx -t accepts the rendered configuration, and the blob location gets" \
  "client_body_buffer_size exactly when config.yaml sets BLOB_UPLOAD_CLIENT_BODY_BUFFER_SIZE"

if [ "$PUSH" != true ]; then
  echo "PUSH=$PUSH: $IMAGE:$TAG was built and tested, and is not pushed"
  exit 0
fi

# 6. Publish, once per tag.
[ "$ENGINE" = docker ] || fail "Only CONTAINER_ENGINE=docker publishes"
AUTH_FILE="${REGISTRY_AUTH_FILE:-${DOCKER_CONFIG:-$HOME/.docker}/config.json}"
[ -f "$AUTH_FILE" ] || fail "PUSH=true needs a registry login in $AUTH_FILE"
# By version alone: upstream rebuilds this tag every day or two and quay.io garbage-collects the digests it leaves,
# so a digest pinned here stops resolving within weeks (the one okd/build.sh pins was gone by 2026-11-15).
SKOPEO_IMAGE=quay.io/skopeo/stable:v1.22.3
skopeo() {
  local -r socket="${DOCKER_HOST:-unix:///var/run/docker.sock}"
  docker run --rm \
    -v "${socket#unix://}:/var/run/docker.sock" \
    -v "$AUTH_FILE:/auth.json:ro" \
    "$SKOPEO_IMAGE" "$@"
}
status_text() {
  echo "$1"
  if [ -n "${TEAMCITY_VERSION:-}" ]; then echo "##teamcity[buildStatus text='{build.status.text}; $1']"; fi
}

# Pulled first, so its pull progress never mixes into an inspect's output.
docker pull -q "$SKOPEO_IMAGE" >/dev/null
if lookup="$(skopeo inspect --authfile /auth.json "docker://$IMAGE:$TAG" 2>"$WORK/lookup.err")"; then
  # Published already: it must be this fork commit over this base, and stays as it is.
  digest="$(python3 -I -c '
import json, sys
d = json.load(sys.stdin)
labels = d.get("Labels") or {}
revision = labels.get("org.opencontainers.image.revision")
base = labels.get("org.opencontainers.image.base.name")
same = (revision, base) == (sys.argv[1], sys.argv[2])
print(d["Digest"] if same else "")' "$FORK_COMMIT" "$BASE_IMAGE" <<<"$lookup")"
  [ -n "$digest" ] || fail "$IMAGE:$TAG exists but is not $FORK_COMMIT over $BASE_IMAGE; it is never pushed over"
  status_text "$IMAGE:$TAG was published already, as $IMAGE@$digest; left as it is"
  exit 0
elif ! grep -q -i 'manifest unknown' "$WORK/lookup.err"; then
  fail "Could not look $IMAGE:$TAG up: $(cat "$WORK/lookup.err")"
fi

skopeo copy --authfile /auth.json --format oci "docker-daemon:$LOCAL" "docker://$IMAGE:$TAG"
media_type="$(skopeo inspect --authfile /auth.json --raw "docker://$IMAGE:$TAG" |
  python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("mediaType", ""))')"
[ "$media_type" = application/vnd.oci.image.manifest.v1+json ] ||
  fail "$IMAGE:$TAG was pushed as $media_type, not a single OCI manifest"
digest="$(skopeo inspect --authfile /auth.json --format '{{.Digest}}' "docker://$IMAGE:$TAG")"
status_text "published $IMAGE:$TAG as $IMAGE@$digest"
