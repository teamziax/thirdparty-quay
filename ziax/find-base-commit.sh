#!/bin/bash
# Finds the commit an upstream Quay image was built from, for source.env's BASE_COMMIT. Upstream pushes an image tag
# such as 3.18.1 from its redhat-<version> branch, not from the git tag of the same name, and can push it again later:
# quay.io/projectquay/quay:3.18.1 came from redhat-3.18 six days of backports after the v3.18.1 tag.
#
# For every file RELEASE_BRANCH changed after FROM_TAG, it compares the image's copy with each commit from FROM_TAG to
# the branch's tip, by git blob hash, and prints how many match. A commit that matches them all is the build commit;
# commits that touched none of the files the image holds match equally, so take the latest of an unbroken run.
#
# Usage: ziax/find-base-commit.sh IMAGE@sha256:<digest> RELEASE_BRANCH FROM_TAG
# For example, with upstream's branch and tags fetched first
# (git fetch upstream redhat-3.18 'refs/tags/v3.18.*:refs/tags/v3.18.*'):
#   ziax/find-base-commit.sh quay.io/projectquay/quay@sha256:94c72496… upstream/redhat-3.18 v3.18.1
# Needs git and docker, or CONTAINER_ENGINE=podman.
set -euo pipefail

[ $# -eq 3 ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2; exit 2; }
image=$1
branch=$2
from=$3
ENGINE="${CONTAINER_ENGINE:-docker}"
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git -C "$REPO" diff --name-only "$from" "$branch" >"$WORK/files"
echo "$(wc -l <"$WORK/files" | tr -d ' ') files changed from $from to $branch"

# The image's copies, hashed as git hashes blobs, by the image's own Python.
"$ENGINE" run --rm -i --entrypoint /usr/bin/python3 "$image" -I -c '
import hashlib, os, sys
for path in sys.stdin.read().split():
    full = os.path.join("/quay-registry", path)
    if os.path.isfile(full):
        data = open(full, "rb").read()
        print(hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest(), path)' <"$WORK/files" >"$WORK/image"
total=$(wc -l <"$WORK/image" | tr -d ' ')
echo "$total of them are in the image"
[ "$total" -gt 0 ] || { echo "None of the files are in the image: is it Quay?" >&2; exit 1; }

matches=()
for commit in $(git -C "$REPO" rev-list --reverse "$from^..$branch"); do
  # One ls-tree per commit: its blob hash for each of the image's files.
  cut -d' ' -f2 "$WORK/image" | xargs git -C "$REPO" ls-tree -r "$commit" -- |
    awk -F'\t' '{split($1, f, " "); print f[3], $2}' >"$WORK/commit"
  matched=$(sort "$WORK/image" | comm -12 - <(sort "$WORK/commit") | wc -l | tr -d ' ')
  printf '%s %s/%s  %s\n' "$(git -C "$REPO" log -1 --format='%h %cs' "$commit")" "$matched" "$total" \
    "$(git -C "$REPO" log -1 --format=%s "$commit" | cut -c1-70)"
  [ "$matched" -eq "$total" ] && matches+=("$commit")
done

if [ "${#matches[@]}" -eq 0 ]; then
  echo "No commit from $from to $branch matches every file" >&2
  exit 1
fi
printf 'Matches every file: %s\n' "${matches[@]}"
