#!/bin/sh
# Runs as root (container default). Fixes ownership of bind-mounted host
# volumes — Docker creates missing bind-mount directories as root:root, which
# the non-root `bun` user then can't write to (config, auth state, workspace) —
# then drops to bun for the real process. Prefer named volumes for
# /app/skills, /home/bun/.claude and /home/bun/.codex when possible: Docker
# seeds a *named* volume from the image's baked-in content on first use, but
# never does this for bind mounts, which hide that content with an empty host
# directory. OpenMemory code lives outside its persistent data volume.
set -e

if [ "$(id -u)" = "0" ]; then
  chown -R bun:bun \
    /app/data /app/workspace /app/skills \
    /home/bun/.claude /home/bun/.codex /home/bun/.config \
    /home/bun/.openmemory /home/bun/.local/share/openmemory \
    /home/bun/.projectmem /home/bun/.headroom
fi

run_as_bun() {
  if [ "$(id -u)" = "0" ]; then
    gosu bun "$@"
  else
    "$@"
  fi
}

# Agent session transcripts accumulate forever and the OpenMemory sync below
# re-reads every one on each start, so old sessions make startup slower without
# bound. Drop transcripts older than the retention window (default 10 days).
# Only session rollouts are touched — auth.json, hooks.json, config and
# history.jsonl live outside these dirs and are left alone.
prune_old_sessions() {
  days="${CCS_SESSION_RETENTION_DAYS:-10}"
  for dir in /home/bun/.claude/projects /home/bun/.codex/sessions; do
    [ -d "$dir" ] || continue
    n="$(find "$dir" -type f -name '*.jsonl' -mtime "+${days}" -print -delete | wc -l)"
    [ "$n" -gt 0 ] && echo "[ccs] sessions: pruned $n transcript(s) older than ${days}d from $dir" >&2
  done
  return 0
}

configure_ccs_mcp() {
  config_path="${CCS_CONFIG_PATH:-/app/data/config.json}"
  mkdir -p "$(dirname "$config_path")"

  if [ ! -f "$config_path" ]; then
    if [ -f /app/config.example.json ]; then
      cp /app/config.example.json "$config_path"
    else
      printf '{}\n' > "$config_path"
    fi
  fi

  config_tmp="$(mktemp "${config_path}.tmp.XXXXXX")"
  if jq '
    .mcpServers //= {} |
    .mcpServers.projectmem //= {
      "type": "stdio",
      "command": "/opt/agent-tools/bin/python",
      "args": ["-m", "projectmem.mcp_server"]
    } |
    .mcpServers.headroom //= {
      "type": "stdio",
      "command": "/opt/agent-tools/bin/headroom",
      "args": ["mcp", "serve"]
    }
  ' "$config_path" > "$config_tmp"; then
    chmod 0600 "$config_tmp"
    mv "$config_tmp" "$config_path"
    if [ "$(id -u)" = "0" ]; then
      chown bun:bun "$config_path"
    fi
  else
    rm -f "$config_tmp"
    return 1
  fi
}

if ! configure_ccs_mcp; then
  echo "[ccs] MCP: invalid CCS config; ProjectMem and Headroom not added." >&2
fi

# CCS launches `claude` inside tmux with stdio ignored, so any first-run prompt
# (theme picker, folder trust, bypass-permissions disclaimer) wedges the pane
# with no visible output and CCS reports only "failed to start tmux session for
# interactive engine". Pre-accept the three prompts. The trust flag on WORKDIR
# is inherited by every project directory below it.
configure_claude_onboarding() {
  workdir="${WORKDIR:-/app/workspace}"
  claude_config=/home/bun/.claude.json
  claude_settings=/home/bun/.claude/settings.json

  [ -f "$claude_config" ] || printf '{}\n' > "$claude_config"
  [ -f "$claude_settings" ] || printf '{}\n' > "$claude_settings"

  config_tmp="$(mktemp "${claude_config}.tmp.XXXXXX")"
  if jq --arg dir "$workdir" '
    .hasCompletedOnboarding = true |
    .theme //= "dark" |
    .projects[$dir].hasTrustDialogAccepted = true
  ' "$claude_config" > "$config_tmp"; then
    mv "$config_tmp" "$claude_config"
  else
    rm -f "$config_tmp"
    return 1
  fi

  settings_tmp="$(mktemp "${claude_settings}.tmp.XXXXXX")"
  if jq '.skipDangerousModePermissionPrompt = true' "$claude_settings" > "$settings_tmp"; then
    mv "$settings_tmp" "$claude_settings"
  else
    rm -f "$settings_tmp"
    return 1
  fi

  if [ "$(id -u)" = "0" ]; then
    chown bun:bun "$claude_config" "$claude_settings"
  fi
}

if ! configure_claude_onboarding; then
  echo "[ccs] Claude: first-run prompts not pre-accepted; interactive sessions may hang." >&2
fi

if ! run_as_bun codex mcp get projectmem >/dev/null 2>&1; then
  if ! run_as_bun codex mcp add projectmem -- \
    /opt/agent-tools/bin/python -m projectmem.mcp_server >/dev/null; then
    echo "[ccs] MCP: could not register ProjectMem in Codex; continuing startup." >&2
  fi
fi

if ! run_as_bun codex mcp get headroom >/dev/null 2>&1; then
  if ! run_as_bun codex mcp add headroom -- \
    /opt/agent-tools/bin/headroom mcp serve >/dev/null; then
    echo "[ccs] MCP: could not register Headroom in Codex; continuing startup." >&2
  fi
fi

prune_old_sessions

echo "[ccs] OpenMemory: syncing Claude sessions to Codex." >&2
if ! run_as_bun openmemory port --from claude-code --to codex --all; then
  echo "[ccs] OpenMemory: Claude to Codex sync failed; continuing startup." >&2
fi

echo "[ccs] OpenMemory: syncing Codex sessions to Claude." >&2
if ! run_as_bun openmemory port --from codex --to claude-code --all; then
  echo "[ccs] OpenMemory: Codex to Claude sync failed; continuing startup." >&2
fi

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
  echo "[ccs]   Run: docker exec -it claude-code-studio codex login --device-auth" >&2
  echo "[ccs]   Enter the printed code at https://auth.openai.com/codex/device from any browser (valid 15 min)." >&2
  echo "[ccs]   Requires device-code sign-in enabled on your ChatGPT account/workspace. If rejected, fall back to:" >&2
  echo "[ccs]     docker exec -it claude-code-studio codex login   (needs a tunnel: ssh -L 1455:localhost:1455 <host>)" >&2
  echo "[ccs]   or copy an already-authenticated ~/.codex/auth.json from a trusted machine into the codex-home volume" >&2
  echo "[ccs]   (only if that file is missing here — codex auto-refreshes it, don't overwrite a live one)." >&2
fi

# Preserve the upstream oven/bun entrypoint behavior: a bare script path still
# runs under bun instead of being exec'd directly.
if [ "${1#-}" != "${1}" ] || [ -z "$(command -v "${1}" 2>/dev/null)" ] || { [ -f "${1}" ] && ! [ -x "${1}" ]; }; then
  set -- /usr/local/bin/bun "$@"
fi

if [ "$(id -u)" = "0" ]; then
  exec gosu bun "$@"
fi

exec "$@"
