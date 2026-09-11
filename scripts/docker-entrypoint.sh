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

# Keep CCS current without a rebuild: compare the commit this tree was built
# from against what CCS_REF resolves to upstream, and reinstall when they
# differ. Opt out with CCS_AUTO_UPDATE=0 (or by pinning CCS_REF to a tag, which
# only moves when the tag does).
#
# The new tree is built COMPLETE in a temp dir and only then swapped in: a
# failed clone or install leaves the running version untouched, because /app is
# the container's writable layer and a half-written one would not start again.
# /app/data, /app/workspace and /app/skills are volumes and are never touched.
# The update lives in that writable layer, so it survives a restart and is
# discarded on a recreate — which pulls a fresh image anyway.
ccs_auto_update() {
  [ "${CCS_AUTO_UPDATE:-1}" = "1" ] || return 0
  [ -n "${CCS_REPO:-}" ] || return 0

  current="$(cat /app/.ccs-revision 2>/dev/null || true)"
  # Two patterns so an annotated tag is peeled to its commit (ls-remote lists
  # the tag object first, then <ref>^{}); `END` takes the peeled one when it
  # exists and the only line otherwise. ccs-fetch.sh records a commit sha, so
  # both sides of the comparison are commits.
  remote="$(git ls-remote "$CCS_REPO" "${CCS_REF:-main}" "${CCS_REF:-main}^{}" 2>/dev/null | awk 'END{print $1}')"
  if [ -z "$remote" ]; then
    echo "[ccs] update: cannot reach $CCS_REPO; keeping the installed version." >&2
    return 0
  fi
  [ "$remote" != "$current" ] || return 0

  echo "[ccs] update: ${current:-unknown} -> ${remote} (${CCS_REF:-main}); installing." >&2
  rm -rf /tmp/ccs-update
  if ! run_as_bun /usr/local/bin/ccs-fetch.sh /tmp/ccs-update \
         "$CCS_REPO" "${CCS_REF:-main}" /usr/local/share/ccs/ccs-sp-file.js >&2; then
    echo "[ccs] update: failed; keeping the installed version." >&2
    rm -rf /tmp/ccs-update
    return 0
  fi

  find /app -mindepth 1 -maxdepth 1 \
    ! -name data ! -name workspace ! -name skills -exec rm -rf {} +
  cp -a /tmp/ccs-update/. /app/
  rm -rf /tmp/ccs-update
  if [ "$(id -u)" = "0" ]; then
    chown -R bun:bun /app
  fi
  echo "[ccs] update: now at ${remote}." >&2
}

ccs_auto_update

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
    find "$dir" -mindepth 1 -type d -empty -delete
  done
  return 0
}

# One definition of both MCP servers, shared by every registration below. CCS
# passes its own config with --mcp-config, while a `claude` started from a
# terminal or docker exec reads only ~/.claude.json; both must offer the same
# two servers or a project is tracked in one kind of session and not the other.
MCP_SERVERS_JSON='{
  "projectmem": {
    "type": "stdio",
    "command": "/opt/agent-tools/bin/python",
    "args": ["-m", "projectmem.mcp_server"]
  },
  "headroom": {
    "type": "stdio",
    "command": "/opt/agent-tools/bin/headroom",
    "args": ["mcp", "serve"]
  }
}'

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
  if jq --argjson servers "$MCP_SERVERS_JSON" \
       '.mcpServers = ($servers + (.mcpServers // {}))' \
       "$config_path" > "$config_tmp"; then
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
# Both files are written in place, never renamed over: a single-file bind mount
# (a host claude.json mapped onto ~/.claude.json) is a mount point, so rename
# fails with EBUSY and the seeding is lost while the container starts fine.
# The same file carries user-scope MCP servers (`claude mcp add -s user` writes
# ~/.claude.json "mcpServers"), which is the only place a `claude` started from a
# CCS terminal pane or `docker exec` looks: CCS's own --mcp-config reaches chat
# runs only, so without this a project is tracked by ProjectMem and Headroom in a
# chat and by neither in a terminal.
# The trust flag is keyed to the EXACT directory Claude starts in and is NOT
# inherited from a parent: with only WORKDIR trusted, a session opened on
# WORKDIR/<project> settles on the trust question instead of the prompt box and
# CCS reports "interactive session went idle without producing a reply". So seed
# WORKDIR and every project directory below it. A project added after startup
# needs a container restart to be seeded.
configure_claude_onboarding() {
  workdir="${WORKDIR:-/app/workspace}"
  claude_config=/home/bun/.claude.json
  claude_settings=/home/bun/.claude/settings.json

  [ -f "$claude_config" ] || printf '{}\n' > "$claude_config"
  [ -f "$claude_settings" ] || printf '{}\n' > "$claude_settings"

  set -- "$workdir"
  for project in "$workdir"/*/; do
    [ -d "$project" ] && set -- "$@" "${project%/}"
  done

  config_tmp="$(mktemp "${claude_config}.tmp.XXXXXX")"
  if jq --argjson servers "$MCP_SERVERS_JSON" --args '
    .hasCompletedOnboarding = true |
    .theme //= "dark" |
    .mcpServers = ($servers + (.mcpServers // {})) |
    reduce $ARGS.positional[] as $dir (.; .projects[$dir].hasTrustDialogAccepted = true)
  ' "$@" < "$claude_config" > "$config_tmp" && cat "$config_tmp" > "$claude_config"; then
    rm -f "$config_tmp"
  else
    rm -f "$config_tmp"
    return 1
  fi

  settings_tmp="$(mktemp "${claude_settings}.tmp.XXXXXX")"
  if jq '.skipDangerousModePermissionPrompt = true' "$claude_settings" > "$settings_tmp" \
     && cat "$settings_tmp" > "$claude_settings"; then
    rm -f "$settings_tmp"
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

# One ProjectMem MCP server serves every project, but only projects in the
# registry (~/.projectmem) can be named on a call. `pjm init` creates
# .projectmem/ in the repo and registers it; it is idempotent, so this re-runs
# on every start and picks up projects added since the last one. A project
# added while the container runs needs a restart, same as the trust seeding
# above. Headroom needs no equivalent: its MCP server is registered globally
# (CCS config, Codex, ~/.claude.json), so every project already reaches it.
# --no-watch: one file-watcher daemon per project per start, with nobody
# reading the churn events, is a leak. --no-claude-md when the project uses
# AGENTS.md and has no CLAUDE.md: `agents-md.js` precedence is exclusive, so
# creating a bridge-only CLAUDE.md would silence that project's real
# conventions.
register_projectmem_projects() {
  workdir="${WORKDIR:-/app/workspace}"
  for project in "$workdir"/*/; do
    project="${project%/}"
    [ -d "$project" ] || continue
    set -- init --no-watch
    if [ -f "$project/AGENTS.md" ] && [ ! -f "$project/CLAUDE.md" ]; then
      set -- "$@" --no-claude-md
    fi
    if ! (cd "$project" && run_as_bun /opt/agent-tools/bin/pjm "$@" >/dev/null 2>&1); then
      echo "[ccs] ProjectMem: could not register $project; continuing startup." >&2
    fi
  done
}

register_projectmem_projects

# HEADROOM_WORKSPACE_DIR / HEADROOM_MEMORY_DB_PATH (Dockerfile) pin Headroom's
# memory to one container-global store, so no session has to decide how memory is
# scoped. `headroom memory` and the memory MCP server resolve
# `<cwd>/.headroom/memory.db` FIRST when that file exists and consult no env var,
# so a single stray project store silently restores per-project memory. Nothing
# here creates one; report it instead of deleting a user's data.
warn_project_headroom_stores() {
  workdir="${WORKDIR:-/app/workspace}"
  for db in "$workdir"/*/.headroom/memory.db; do
    [ -f "$db" ] || continue
    echo "[ccs] Headroom: project store $db overrides the global one; remove it to keep memory global." >&2
  done
  return 0
}

warn_project_headroom_stores

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
