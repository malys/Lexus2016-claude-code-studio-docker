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
         "$CCS_REPO" "${CCS_REF:-main}" >&2; then
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
# re-reads every one on each start. Worse, `openmemory port --all` re-ports the
# copies it wrote itself (A->B->A clone chain, a documented upstream limitation):
# every start turned each ported session into one more fresh-mtime copy, so an
# age-based prune never caught them and the store grew until the disk filled.
# Keep only the newest native sessions per agent, cap OpenMemory copies at what
# the other agent can still produce, and port the kept natives by --id.
# Only session transcripts are touched — auth.json, hooks.json, config and
# history.jsonl live outside these dirs and are left alone.
CLAUDE_SESSIONS_KEEP="${CCS_CLAUDE_SESSIONS_KEEP:-20}"
CODEX_SESSIONS_KEEP="${CCS_CODEX_SESSIONS_KEEP:-10}"

# prune_sessions DIR MARKER KEEP_NATIVE KEEP_COPIES [find options...]
# A transcript whose first line contains MARKER is an OpenMemory copy. Deletes
# everything past the newest KEEP_* of each kind (plus a Claude session's
# <id>/ subagent dir) and prints the kept native paths, newest first.
prune_sessions() {
  dir="$1" marker="$2" keep_native="$3" keep_copy="$4"
  shift 4
  [ -d "$dir" ] || return 0
  find "$dir" "$@" -type f -name '*.jsonl' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2- | {
    natives=0 copies=0 pruned=0
    while IFS= read -r f; do
      if head -n 1 "$f" | grep -q "$marker"; then
        copies=$((copies + 1))
        [ "$copies" -le "$keep_copy" ] && continue
      else
        natives=$((natives + 1))
        if [ "$natives" -le "$keep_native" ]; then printf '%s\n' "$f"; continue; fi
      fi
      rm -rf "$f" "${f%.jsonl}"
      pruned=$((pruned + 1))
    done
    if [ "$pruned" -gt 0 ]; then
      echo "[ccs] sessions: pruned $pruned transcript(s) from $dir" >&2
    fi
  }
  find "$dir" -mindepth 1 -type d -empty -delete
}

# port_sessions FROM TO IDS — IDS is a whitespace-separated session id list.
port_sessions() {
  from="$1" to="$2" ids="$3"
  [ -n "$ids" ] || return 0
  set --
  for id in $ids; do set -- "$@" --id "$id"; done
  echo "[ccs] OpenMemory: syncing $from sessions to $to." >&2
  if ! run_as_bun openmemory port --from "$from" --to "$to" "$@"; then
    echo "[ccs] OpenMemory: $from to $to sync failed; continuing startup." >&2
  fi
}

# CCS gives every session, task and chain its own git worktree under
# /app/data/worktrees/<project>/<unit>, but its session cleanup
# (SESSION_TTL_DAYS, default 30) only deletes the DB row, never the worktree,
# so they pile up. Remove every worktree no DB row references any more. Runs
# before CCS starts, so nothing can be creating one meanwhile. No work is lost:
# `git worktree remove` without --force refuses a tree with uncommitted or
# untracked changes, and `branch -d` refuses an unmerged branch.
prune_orphan_worktrees() {
  root=/app/data/worktrees
  [ -d "$root" ] && [ -f /app/data/chats.db ] || return 0
  # Fail safe: if the DB can't be read, every worktree counts as in use.
  # Explicit exit code: `bun -e` exits 0 on an uncaught error.
  if ! used="$(run_as_bun bun -e '
    try {
      const db = new (require("bun:sqlite").Database)("/app/data/chats.db", { readonly: true });
      for (const t of ["sessions", "tasks", "task_chains"])
        for (const r of db.query(`SELECT workdir FROM ${t} WHERE workdir IS NOT NULL`).all())
          console.log(r.workdir);
    } catch (e) { console.error(e.message); process.exit(1); }
  ')"; then
    echo "[ccs] worktrees: cannot read chats.db; skipping prune." >&2
    return 0
  fi
  pruned=0 kept=0
  for wt in "$root"/*/*; do
    [ -d "$wt" ] || continue
    printf '%s\n' "$used" | grep -qxF "$wt" && continue
    # Not a worktree at all (crash between mkdir and `worktree add`).
    if [ ! -e "$wt/.git" ]; then rm -rf "$wt"; continue; fi
    repo="$(run_as_bun git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" || continue
    branch="$(run_as_bun git -C "$wt" symbolic-ref --quiet --short HEAD)" || branch=
    if run_as_bun git --git-dir="$repo" worktree remove "$wt" 2>/dev/null; then
      pruned=$((pruned + 1))
      [ -z "$branch" ] || run_as_bun git --git-dir="$repo" branch -d "$branch" >/dev/null 2>&1 || true
    else
      kept=$((kept + 1))
    fi
  done
  find "$root" -mindepth 1 -maxdepth 1 -type d -empty -delete
  [ "$pruned" -eq 0 ] || echo "[ccs] worktrees: removed $pruned orphan worktree(s)." >&2
  [ "$kept" -eq 0 ] || echo "[ccs] worktrees: kept $kept orphan worktree(s) with uncommitted changes." >&2
  return 0
}

# The image links every tokless-installed package's skills into
# ~/.claude/skills at BUILD time and mirrors them into /app/skills. Both are
# named volumes, and Docker seeds a named volume from the image only while that
# volume is EMPTY: a volume created by an earlier image keeps its old content
# forever, so skills a newer image added (context-mode's ctx-search, ctx-index,
# ctx-doctor, ...) never appear. The binary, its MCP servers and ~/.claude.json
# are image-layer/entrypoint-managed and stay fine, which is why the symptom
# reads as "tokless is no longer installed" while `tokless` itself reports every
# tool green. Re-link on every start; idempotent.
# A real directory of the same name is left alone (a user-installed skill wins);
# only a symlink is refreshed, which also repairs one left dangling by an
# upgrade that renamed the package directory.
link_tokless_skills() {
  skills_dir=/home/bun/.claude/skills
  mkdir -p "$skills_dir" /app/skills

  for pkg_skills in /home/bun/.local/lib/node_modules/*/skills/*; do
    [ -d "$pkg_skills" ] || continue
    target="$skills_dir/$(basename "$pkg_skills")"
    if [ -L "$target" ]; then
      ln -sfn "$pkg_skills" "$target" || return 1
    elif [ ! -e "$target" ]; then
      ln -s "$pkg_skills" "$target" || return 1
    fi
  done

  # CCS scans /app/skills, Claude Code scans ~/.claude/skills. Same mirror the
  # Dockerfile performs, for the same reason: the CCS-level system prompt has to
  # see the skills too. cp -a copies the symlinks as symlinks, which resolve
  # inside the container.
  cp -a "$skills_dir"/. /app/skills/ 2>/dev/null || true

  if [ "$(id -u)" = "0" ]; then
    chown -h -R bun:bun "$skills_dir" /app/skills
  fi
}

# tokless wires its tools into ~/.claude, ~/.claude.json and ~/.codex at build
# time. Those paths are usually bind-mounted from the host, which hides the
# image's copy, so the tools read as "not installed" after a recreate. The tools
# themselves live in ~/.local (image layer); re-run the idempotent wiring step
# on every start so it lands in whatever config is mounted.
if ! run_as_bun tokless --agents claude,codex >/dev/null 2>&1; then
  echo "[ccs] tokless: wiring failed; run 'tokless doctor' in the container." >&2
fi

if ! link_tokless_skills; then
  echo "[ccs] tokless: could not link package skills; ctx-* skills may be missing." >&2
fi

# CCS_AGENT_RULES: instructions every Claude and Codex session must get (e.g.
# "no heavy builds/tests on this 12 GB host"). The tokless run above treats
# everything from its first managed block to EOF as its own and rewrites it, so
# a rule appended at the END of ~/.claude/CLAUDE.md (the file CCS's global
# instructions editor opens) or ~/.codex/AGENTS.md is wiped on the next start.
# Text ABOVE the managed blocks survives, so pin the rules there between
# markers, refreshed on every start. Unset the variable to drop the block.
pin_agent_rules() {
  begin='<!-- ccs-agent-rules:begin -->'
  end='<!-- ccs-agent-rules:end -->'
  for file in /home/bun/.claude/CLAUDE.md /home/bun/.codex/AGENTS.md; do
    [ -f "$file" ] || [ -n "${CCS_AGENT_RULES:-}" ] || continue
    [ -f "$file" ] || : > "$file"
    tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if {
      if [ -n "${CCS_AGENT_RULES:-}" ]; then
        printf '%s\n%s\n%s\n\n' "$begin" "$CCS_AGENT_RULES" "$end"
      fi
      awk -v b="$begin" -v e="$end" '
        $0 == b { skip = 1; next }
        skip && $0 == e { skip = 0; blank = 1; next }
        skip { next }
        blank && $0 == "" { blank = 0; next }
        { blank = 0; print }
      ' "$file"
    } > "$tmp" && cat "$tmp" > "$file"; then
      rm -f "$tmp"
    else
      rm -f "$tmp"
      return 1
    fi
    if [ "$(id -u)" = "0" ]; then
      chown bun:bun "$file"
    fi
  done
}

if ! pin_agent_rules; then
  echo "[ccs] CCS_AGENT_RULES: could not pin agent rules; sessions may run without them." >&2
fi

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

# CodeGraph keeps one index per project in <project>/.codegraph, and nothing
# creates it for a project added after the image was built — so a new project is
# invisible to the codegraph MCP server and every agent silently falls back to
# grep. `codegraph init -y` is non-interactive and idempotent, but a FIRST index
# of a large repo takes minutes, so the sweep runs in the background: CCS must
# still answer on :3000 immediately. Only projects with no .codegraph are
# touched; the daemon that init leaves behind keeps that project in sync from
# then on. Set CCS_CODEGRAPH_INDEX=0 to skip it entirely.
# NOTE this is also why the chown -R at the top of this script matters for
# /app/workspace: a `docker exec` into this container lands as ROOT with
# HOME=/home/bun, so a `tokless`/`codegraph` run from such a shell writes a
# root-owned .codegraph/ that the bun-owned server can only report as
# "attempt to write a readonly database". The chown heals it on the next start.
index_workspace_projects() {
  workdir="${WORKDIR:-/app/workspace}"
  for project in "$workdir"/*/; do
    project="${project%/}"
    [ -d "$project" ] || continue
    if [ -d "$project/.codegraph" ]; then
      continue
    fi
    echo "[ccs] CodeGraph: indexing $project (first time; runs in background)" >&2
    if run_as_bun /home/bun/.local/bin/codegraph init -y "$project" >/dev/null 2>&1; then
      echo "[ccs] CodeGraph: indexed $project" >&2
    else
      echo "[ccs] CodeGraph: could not index $project; agents fall back to grep there." >&2
    fi
  done
  return 0
}

if [ "${CCS_CODEGRAPH_INDEX:-1}" = "1" ] && [ -x /home/bun/.local/bin/codegraph ]; then
  index_workspace_projects &
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

# Claude session id = file name. Codex = session_meta.session_id, which a child
# thread shares with its parent, so it is not always the uuid in the file name.
claude_ids="$(prune_sessions /home/bun/.claude/projects openmemorySource \
  "$CLAUDE_SESSIONS_KEEP" "$CODEX_SESSIONS_KEEP" -mindepth 2 -maxdepth 2 |
  while IFS= read -r f; do basename "$f" .jsonl; done)"
codex_ids="$(prune_sessions /home/bun/.codex/sessions '"originator":"openmemory"' \
  "$CODEX_SESSIONS_KEEP" "$CLAUDE_SESSIONS_KEEP" |
  while IFS= read -r f; do
    head -n 1 "$f" | grep -o '"session_id":"[^"]*"' | head -n 1 | cut -d'"' -f4
  done | sort -u)"

port_sessions claude-code codex "$claude_ids"
port_sessions codex claude-code "$codex_ids"

prune_orphan_worktrees

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
