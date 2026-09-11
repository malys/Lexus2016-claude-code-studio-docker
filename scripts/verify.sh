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
  command -v node
  test -f /app/server.js
  test -s /app/.ccs-revision
  jq -e '\''.mcpServers.projectmem.command == "/opt/agent-tools/bin/python"'\'' /app/data/config.json >/dev/null
  jq -e '\''.mcpServers.headroom.args == ["mcp", "serve"]'\'' /app/data/config.json >/dev/null
  codex mcp get projectmem >/dev/null
  codex mcp get headroom >/dev/null
  jq -e '\''.hasCompletedOnboarding == true'\'' /home/bun/.claude.json >/dev/null
  jq -e '\''.mcpServers.projectmem.command == "/opt/agent-tools/bin/python"'\'' /home/bun/.claude.json >/dev/null
  jq -e '\''.mcpServers.headroom.args == ["mcp", "serve"]'\'' /home/bun/.claude.json >/dev/null
  jq -e '\''.projects["/app/workspace"].hasTrustDialogAccepted == true'\'' /home/bun/.claude.json >/dev/null
  jq -e '\''.skipDangerousModePermissionPrompt == true'\'' /home/bun/.claude/settings.json >/dev/null
  test "$(id -u)" != "0"
  echo "Smoke test passed"
'

# A fresh container has an empty workspace, so the registration loop above has
# nothing to prove. Seed a project directory and re-run the entrypoint (it is
# idempotent up to the final exec) to check it lands in the registry.
docker run --rm "$IMAGE" bash -lc '
  set -e
  mkdir -p /app/workspace/smoke-proj
  docker-entrypoint.sh true
  test -d /app/workspace/smoke-proj/.projectmem
  gosu bun /opt/agent-tools/bin/pjm project list | grep -q smoke-proj
  echo "ProjectMem registration test passed"
  cd /app/workspace/smoke-proj
  test "$(/opt/agent-tools/bin/python -c "from headroom.paths import memory_db_path as m; print(m())")" = /home/bun/.headroom/memory.db
  test "$(/opt/agent-tools/bin/python -c "from headroom.cli.memory import _default_db_path as d; print(d())")" = /home/bun/.headroom/memory.db
  echo "Headroom global memory test passed"
'

docker run --rm --user bun "$IMAGE" bash -lc '
  set -e
  test "$(id -u)" != "0"
  command -v codex
  echo "Non-root entrypoint test passed"
'
