#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-ccs-full:test}"

docker run --rm "$IMAGE" bash -lc '
  set -e
  command -v claude
  command -v codex
  command -v tokless
  command -v openmemory
  /opt/agent-tools/bin/pjm --help >/dev/null
  /opt/agent-tools/bin/headroom --version
  openmemory --help >/dev/null
  openmemory port --from claude-code --to codex --all >/dev/null
  openmemory port --from codex --to claude-code --all >/dev/null
  command -v tmux
  test -f /app/server.js
  jq -e '\''.mcpServers.projectmem.command == "/opt/agent-tools/bin/python"'\'' /app/data/config.json >/dev/null
  jq -e '\''.mcpServers.headroom.args == ["mcp", "serve"]'\'' /app/data/config.json >/dev/null
  codex mcp get projectmem >/dev/null
  codex mcp get headroom >/dev/null
  test "$(id -u)" != "0"
  echo "Smoke test passed"
'

docker run --rm --user bun "$IMAGE" bash -lc '
  set -e
  test "$(id -u)" != "0"
  command -v codex
  echo "Non-root entrypoint test passed"
'
