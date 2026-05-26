#!/usr/bin/env bash
# build-package.sh — entrypoint for ceph-builder:<distro>-<arch>.
#
# Per issue #10's acceptance criteria, the builder image ships with a
# `build-package.sh` entrypoint. This is the thin router that lets the
# same image work for three callers:
#
#   1. INTERACTIVE — `tkn pipeline start build-builder-image` with the
#      image bound to a workspace. With no args, drop into an
#      interactive bash so the developer can poke around (`which gcc`,
#      `rpm -q python3-devel`, etc.).
#
#   2. PACKAGE-BUILD TASK (#16, not yet landed) — invokes the image
#      with explicit args like:
#         build-package.sh /workspace/source/ceph rpm
#         build-package.sh /workspace/source/ceph deb
#      and we exec the right `rpmbuild` / `dpkg-buildpackage` against
#      the mounted source tree.
#
#   3. REPRODUCIBILITY-CHECK (#48) — invokes the image with an
#      arbitrary `build-command` string. We pass it straight through
#      to bash -c so the existing Task contract (a shell command in,
#      build artefacts out) keeps working without per-image plumbing.
#
# The router is deliberately tiny: no flag parsing, no config files.
# The decision tree is `# args -> what to do`:
#
#   0 args   -> exec bash (interactive)
#   1 arg    -> exec bash -c "$1"   (the reproducibility-check shape)
#   2+ args, first is a directory
#            -> cd into it, then `bash -c "$2 ${@:3}"`
#               (the package-build shape: `WORKDIR CMD [extra-args]`)
#   2+ args, first is not a directory
#            -> exec "$@"            (treat as a literal argv)
#
# All env hygiene (SOURCE_DATE_EPOCH, LC_ALL, TZ, umask, CFLAGS) is
# the CALLER's responsibility — the reproducibility-check Task
# already exports the canonical stanza before invoking the
# build-command, and the future package-build Task will do the same.
# We do NOT want the entrypoint silently overriding the caller's
# choices.

set -euo pipefail

# Print a banner so the image's identity is in every TaskRun's log
# tail without the caller having to add a separate echo step. Reads
# the OCI labels via `os-release` style — sourced from the
# Containerfile LABELs at build time and persisted into
# /etc/ceph-builder-image.env so we don't have to inspect labels
# from inside the running container (which is awkward without
# skopeo).
if [ -r /etc/ceph-builder-image.env ]; then
  # shellcheck disable=SC1091
  . /etc/ceph-builder-image.env
  echo "[ceph-builder] image: ${CEPH_BUILDER_IMAGE_TITLE:-ceph-builder}"
  echo "[ceph-builder] version: ${CEPH_BUILDER_IMAGE_VERSION:-unknown}"
  echo "[ceph-builder] ceph-sha: ${CEPH_BUILDER_CEPH_SHA:-unknown}"
fi

case "$#" in
  0)
    echo "[ceph-builder] no args; dropping to interactive bash"
    exec bash
    ;;
  1)
    # Single string: the reproducibility-check shape. The caller
    # has already exported SOURCE_DATE_EPOCH et al; we just run it.
    echo "[ceph-builder] running: $1"
    exec bash -c "$1"
    ;;
  *)
    first="$1"; shift
    if [ -d "${first}" ]; then
      # Two-or-more args, first looks like a directory: cd in and
      # exec the rest as a single shell command. Matches the
      # package-build Task's expected invocation
      # (`build-package.sh /workspace/source <build-cmd>`).
      cd "${first}"
      echo "[ceph-builder] cd ${first}; running: $*"
      exec bash -c "$*"
    else
      # Otherwise: literal argv. Lets the caller invoke
      # `build-package.sh rpmbuild -bb ...` directly.
      echo "[ceph-builder] exec: ${first} $*"
      exec "${first}" "$@"
    fi
    ;;
esac
