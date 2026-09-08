#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-ccs-full:test}"

docker run --rm "$IMAGE" bash -lc '
  set -e
  command -v claude
  command -v codex
  command -v tokless
  command -v openmemory
  command -v tmux
  test -f /app/server.js
  test "$(id -u)" != "0"
  echo "Smoke test passed"
'

docker run --rm --user bun "$IMAGE" bash -lc '
  set -e
  test "$(id -u)" != "0"
  command -v codex
  echo "Non-root entrypoint test passed"
'
