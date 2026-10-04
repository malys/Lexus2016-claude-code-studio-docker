#!/bin/sh
# Fetch a CCS tree ready to run: clone, install production deps, trim.
#
# Shared by the Dockerfile builder and by the entrypoint's startup updater so
# both produce an identical tree.
#
# Usage: ccs-fetch.sh <dest> <repo> <ref>
set -e

dest="$1"
repo="$2"
ref="$3"

git clone --depth 1 --branch "$ref" "$repo" "$dest"
cd "$dest"

# The revision this tree was built from. The updater compares it against
# `git ls-remote`, which peels an annotated tag to its commit — so record the
# commit, not the tag object, or every restart would "update" a pinned build.
git rev-parse HEAD > .ccs-revision
rm -rf .git .github .planning test electron homebrew-tap build

# npm/bun install rather than a lockfile-strict install so the tree also builds
# when the upstream repository changes lockfile/package-manager details.
bun install --omit=dev
