# Build image: ziax/build.sh on TeamCity, publishing to quay.io/ziax/quay as the robot in QUAY_USERNAME and
# QUAY_PASSWORD. While those are not set up (MISSING_INPUTS, from settings.kts), or deploy.push.enabled is not true, it
# builds and smoke-tests the image and pushes nothing.
set -euo pipefail

# DOCKER_CONFIG is in the build's temporary directory, which TeamCity empties after every build, so a registry login
# never outlives the build that made it and no other build's login is visible to this one: the agents share one home
# directory. The docker CLI looks for its plugins (buildx) under DOCKER_CONFIG, so the agent user's own plugins stay
# visible.
mkdir -p "$DOCKER_CONFIG"
if [ -d "$HOME/.docker/cli-plugins" ] && [ ! -e "$DOCKER_CONFIG/cli-plugins" ]; then
  ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG/cli-plugins"
fi

# skopeo, which build.sh runs in a container, reads this file and no other. Without a login it pulls anonymously:
# quay.io/ziax/quay and the upstream image are public.
export REGISTRY_AUTH_FILE="$DOCKER_CONFIG/config.json"
[ -f "$REGISTRY_AUTH_FILE" ] || echo '{"auths":{}}' > "$REGISTRY_AUTH_FILE"

if [ "${DEPLOY_PUSH:-}" != true ]; then
  echo "deploy.push.enabled is '${DEPLOY_PUSH:-}': this build builds and tests the image, and publishes nothing"
  PUSH=false bash ziax/build.sh
  exit 0
fi
if [ -n "${MISSING_INPUTS:-}" ]; then
  PUSH=false bash ziax/build.sh
  echo "##teamcity[buildProblem description='Built and tested, not published: $MISSING_INPUTS" \
    "not set up on TeamCity yet (.teamcity/README.md)']"
  exit 1
fi

echo "$QUAY_PASSWORD" | docker login quay.io --username "$QUAY_USERNAME" --password-stdin
# Log out when the step ends, published or not.
trap 'docker logout quay.io >/dev/null 2>&1 || true' EXIT
# skopeo runs in a container, so a login held by a credential helper would not reach it.
if ! python3 -I -c '
import json, sys
auths = json.load(open(sys.argv[1])).get("auths", {})
sys.exit(0 if auths.get("quay.io", {}).get("auth") else 1)' "$REGISTRY_AUTH_FILE"; then
  echo "##teamcity[buildProblem description='docker login did not write the quay.io login into" \
    "$REGISTRY_AUTH_FILE, where skopeo reads it']"
  exit 1
fi

PUSH=true bash ziax/build.sh
