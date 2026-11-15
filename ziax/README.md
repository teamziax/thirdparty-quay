# quay.io/ziax/quay

This branch is Ziax's Quay: upstream's image, with this branch's changes written over it. man1-prod1 runs it as `cr.ziax.ltd`, in place of the operator's own image: cluster-configuration's `project-quay` Subscription names it in `RELATED_IMAGE_COMPONENT_QUAY` (`components/operators/base/quay/project-quay.yaml`). The fork is temporary. It carries changes until a Quay release has them, and then the override goes.

## What this branch changes

One commit on top of upstream: `BLOB_UPLOAD_CLIENT_BODY_BUFFER_SIZE`, which Quay renders as nginx's `client_body_buffer_size` in the blob-upload location ([PROJQUAY-2855](https://redhat.atlassian.net/browse/PROJQUAY-2855), *Slow uploads when using HTTP2*). man1-prod1's `config.yaml` sets it to `4m`.

- **Why.** Quay streams blob uploads to its registry workers unbuffered. For an HTTP/2 upload, nginx then makes the stream's flow-control window as large as its body buffer, 64 KiB by default, so a client can send only 64 KiB per round trip: 0.85 MB/s from the TeamCity agents, 77 ms away, against 14 MB/s over HTTP/1.1.
- **Tested.** This image with `4m`, behind a simulated 77 ms link capped at 14 MB/s, took HTTP/2 uploads from 0.82 MB/s to 13.13 MB/s, the same as HTTP/1.1 (13.11 MB/s). Each upload in flight holds up to that much nginx memory.
- **Upstream.** The same change, with tests, is on `bruce/blob-upload-client-body-buffer-size`, based on master and following upstream's #7714 (`BLOB_UPLOAD_CLIENT_BODY_TIMEOUT`), for an upstream pull request.

## How it is built

*Build image* on TeamCity runs `build.sh` for every push to a `ziax/*` branch (`.teamcity/README.md`). `source.env` pins what it builds on:

- `BASE_IMAGE`: upstream's `quay.io/projectquay/quay:3.18.1` for linux/amd64, by digest. It is the image man1-prod1 ran before this one.
- `BASE_COMMIT`: the commit that image was built from. **It is not the `v3.18.1` git tag**: upstream pushed the `3.18.1` image on 2026-10-13 from `redhat-3.18` six days of backports later, and a branch based on the tag would undo those backports in every file it writes over. `find-base-commit.sh` finds it (see *Upgrading Quay*).

`build.sh`:

1. Checks that the commit being built descends from `BASE_COMMIT`.
2. Lists what the commit changes since then. `ziax/`, `.teamcity/` and tests are not part of the image. Only changed Python modules and Jinja templates can be carried, and not under `config-tool/`, `web/` or `static/`, which upstream's build compiles or bundles. Anything else fails the build, because it needs a full build of upstream's Containerfile.
3. Checks that `BASE_IMAGE` holds `BASE_COMMIT`'s version of each of those files.
4. Writes each file's content into the base image's file (`Containerfile`), so every owner and mode bit stays as upstream set it. OpenShift runs Quay as an arbitrary user in group 0, which relies on the group-write bits on `conf/`.
5. Smoke-tests the image as such a user. It renders Quay's nginx configuration with the image's own generator, as the image does at boot, runs `nginx -t`, and checks that the blob location gets `client_body_buffer_size` exactly when `config.yaml` sets it.
6. With `PUSH=true`, publishes the image as `quay.io/ziax/quay:<BASE_VERSION>-<first 12 hex of the commit>`, a single OCI manifest pushed with skopeo, and prints its digest. A tag is published once and never pushed over: the Subscription pins the digest, and quay.io garbage-collects a digest that no tag names. If the tag already holds this commit over this base, the build reports its digest and succeeds.

Every commit gets its own tag, including commits that change only `ziax/` or `.teamcity/`; their images are identical in content to their parent's. man1-prod1 moves to a new image only when cluster-configuration's Subscription names its digest.

Locally, `ziax/build.sh` builds and tests the committed `HEAD` with docker and pushes nothing. With rootless podman: `CONTAINER_ENGINE=podman SMOKE_UID=12345 ziax/build.sh`, since rootless podman maps too few user IDs for OpenShift's.

## Changing it

- **Another change.** Commit it to a branch named `ziax/3.18.1-<topic>`, whose builds publish too, so it can be tried, then merge it into `ziax/3.18.1`. Put the digest *Build image* prints into `RELATED_IMAGE_COMPONENT_QUAY` in cluster-configuration.
- **Upgrading Quay.** The operator migrates the database only when its own version changes, and it migrates with whatever image the override names. With the override still in place, an operator upgrade would run the old release's migrations, record the new version, and never run the new ones. So, in this order:
  1. In cluster-configuration, remove `RELATED_IMAGE_COMPONENT_QUAY` from the Subscription, so the operator goes back to upstream's image of its own version.
  2. Approve the operator's upgrade, which runs the new release's migrations with upstream's image.
  3. Find the commit the new upstream image was built from: `ziax/find-base-commit.sh quay.io/projectquay/quay@sha256:<new digest> upstream/redhat-<x.y> v<new version>`, after fetching upstream's branch and tags. Branch `ziax/<new version>` from it, carry this branch's commits over, and set the `BASE_` values. Make the new branch the VCS root's default branch, so TeamCity reads its settings. Then put its image's digest back in the Subscription.
