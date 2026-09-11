#!/bin/sh
# Fetch a CCS tree ready to run: clone, patch, install production deps, trim.
#
# Shared by the Dockerfile builder and by the entrypoint's startup updater so
# both produce an identical tree. The tmux system-prompt patch below must exist
# in exactly one place: a copy that drifts means a rebuilt image and a
# self-updated container run different code.
#
# Usage: ccs-fetch.sh <dest> <repo> <ref> <sp-patch-file>
set -e

dest="$1"
repo="$2"
ref="$3"
patch_src="$4"

git clone --depth 1 --branch "$ref" "$repo" "$dest"
cd "$dest"

# tmux caps a single command string at ~16 KB (its imsg limit), but CCS builds
# the whole system prompt into the command it hands to `tmux new-session`, and
# that prompt carries the project's AGENTS.md (up to 64 KB). A project with a
# large AGENTS.md therefore never starts and CCS only reports "failed to start
# tmux session for interactive engine". Spill the prompt to a file instead.
cp "$patch_src" ./ccs-sp-file.js
grep -q 'innerCmd += ` --append-system-prompt ${shq(sp)}`' claude-interactive.js \
    && sed -i 's|innerCmd += ` --append-system-prompt ${shq(sp)}`|innerCmd += ` --append-system-prompt "$(cat ${shq(require("./ccs-sp-file.js")(sp))})"`|' claude-interactive.js

# The revision this tree was built from. The updater compares it against
# `git ls-remote`, which peels an annotated tag to its commit — so record the
# commit, not the tag object, or every restart would "update" a pinned build.
git rev-parse HEAD > .ccs-revision
rm -rf .git .github .planning test electron homebrew-tap build

# npm/bun install rather than a lockfile-strict install so the tree also builds
# when the upstream repository changes lockfile/package-manager details.
bun install --omit=dev
