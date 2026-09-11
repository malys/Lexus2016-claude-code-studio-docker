#!/bin/sh
# Self-check for scripts/ccs-fetch.sh and the revision comparison the startup
# updater does. Needs git and bun on PATH; touches nothing outside its tmp dir.
#
#   sh scripts/test-ccs-fetch.sh
set -e

here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway repo shaped like CCS: the one line ccs-fetch.sh patches, plus
# directories the trim step must remove.
mkdir -p "$work/upstream/test" "$work/upstream/.github"
cd "$work/upstream"
printf '{"name":"fake-ccs","version":"1.0.0"}\n' > package.json
printf 'console.log("v1");\n' > server.js
printf 'function f(sp){ innerCmd += ` --append-system-prompt ${shq(sp)}`; }\n' > claude-interactive.js
touch test/a.js .github/x.yml
git init -q -b main .
git add -A
git -c user.email=t@t -c user.name=t commit -qm v1
git -c user.email=t@t -c user.name=t tag -a v1.0.0 -m rel

sh "$here/scripts/ccs-fetch.sh" "$work/dest" "$work/upstream" main \
   "$here/patches/ccs-sp-file.js" >/dev/null 2>&1

fail() { echo "FAIL: $1" >&2; exit 1; }

grep -q 'cat ${shq(require("./ccs-sp-file.js")(sp))}' "$work/dest/claude-interactive.js" \
  || fail "tmux system-prompt patch not applied"
[ -f "$work/dest/ccs-sp-file.js" ] || fail "patch helper not installed in the tree"
! [ -d "$work/dest/.git" ] || fail ".git not trimmed"
! [ -d "$work/dest/test" ] || fail "test/ not trimmed"
[ -d "$work/dest/node_modules" ] || fail "dependencies not installed"

# The updater compares `git ls-remote <ref> <ref>^{}` against this file. An
# annotated tag resolves to a tag object on the first line and to its commit on
# the second, so the peeled value is the one that matches — take anything else
# and a pinned build reinstalls itself on every start.
rev="$(cat "$work/dest/.ccs-revision")"
[ "$rev" = "$(git -C "$work/upstream" rev-parse HEAD)" ] || fail ".ccs-revision is not the commit"
peeled="$(git ls-remote "$work/upstream" v1.0.0 'v1.0.0^{}' | awk 'END{print $1}')"
[ "$peeled" = "$rev" ] || fail "annotated tag does not peel to the recorded commit"

echo "ccs-fetch self-check passed"
