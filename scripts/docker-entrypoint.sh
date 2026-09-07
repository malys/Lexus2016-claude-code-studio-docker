#!/bin/sh
# Runs as root (container default). Fixes ownership of bind-mounted host
# volumes — Docker creates missing bind-mount directories as root:root, which
# the non-root `bun` user then can't write to (config, auth state, workspace) —
# then drops to bun for the real process. Prefer named volumes for
# /app/skills, /home/bun/.claude, /home/bun/.codex and
# /home/bun/.local/share/openmemory when possible: Docker seeds a *named*
# volume from the image's baked-in content (tokless skills, OpenMemory
# source) on first use, but never does this for bind mounts, which just
# shadow that content with an empty host directory.
set -e

chown -R bun:bun \
  /app/data /app/workspace /app/skills \
  /home/bun/.claude /home/bun/.codex /home/bun/.config \
  /home/bun/.openmemory /home/bun/.local/share/openmemory

# Login reminders. A real claude setup-token value always starts with
# sk-ant-oat01- — anything else is rejected by the `claude` CLI, which then
# asks for /login inside the chat itself (looks like CCS is blocking login;
# it isn't, the token is just wrong/garbled/missing).
if [ ! -f /home/bun/.claude/.credentials.json ] \
   && ! printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | grep -q '^sk-ant-oat01-' \
   && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[ccs] Claude: not authenticated." >&2
  echo "[ccs]   Subscription: run 'claude setup-token' on a machine with a browser (logged into your Pro/Max account)," >&2
  echo "[ccs]   then set CLAUDE_CODE_OAUTH_TOKEN to the printed sk-ant-oat01-... value." >&2
  echo "[ccs]   Or one-time interactive: docker exec -it claude-code-studio claude login (persists in the claude-home volume)." >&2
fi
if [ ! -f /home/bun/.codex/auth.json ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "[ccs] Codex: not authenticated." >&2
  echo "[ccs]   Run: docker exec -it claude-code-studio codex login" >&2
  echo "[ccs]   Remote host: tunnel its callback port first, e.g. ssh -L 1455:localhost:1455 <host>, then run the exec above." >&2
fi

# Preserve the upstream oven/bun entrypoint behavior: a bare script path still
# runs under bun instead of being exec'd directly.
if [ "${1#-}" != "${1}" ] || [ -z "$(command -v "${1}" 2>/dev/null)" ] || { [ -f "${1}" ] && ! [ -x "${1}" ]; }; then
  set -- /usr/local/bin/bun "$@"
fi

exec gosu bun "$@"
