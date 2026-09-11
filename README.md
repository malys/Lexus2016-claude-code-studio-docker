# Claude Code Studio — Full Docker Image

Standalone batteries-included Docker image for [Claude Code Studio](https://github.com/Lexus2016/claude-code-studio).

This repository is intentionally independent from the CCS source repository. The Docker build fetches the selected CCS git ref at build time, installs Claude Code and Codex, adds `tmux`, configures `tokless` for Claude + Codex, and installs OpenMemory.

## Published image

The default CI target is:

```text
ghcr.io/<owner>/claude-code-studio:full
ghcr.io/<owner>/claude-code-studio:latest-full
```

The workflow also supports immutable release tags such as:

```text
ghcr.io/<owner>/claude-code-studio:full-v7.16.2
```

The package is created from this repository's GHCR publishing workflow; it does **not** depend on an existing `ghcr.io/lexus2016/claude-code-studio:latest` base image.

## Run

```bash
docker run -d \
  --name claude-code-studio \
  -p 3000:3000 \
  -v ccs-data:/app/data \
  -v ccs-workspace:/app/workspace \
  -v ccs-skills:/app/skills \
  -v ccs-claude:/home/bun/.claude \
  -v ccs-codex:/home/bun/.codex \
  -v ccs-config:/home/bun/.config \
  -v ccs-openmemory:/home/bun/.openmemory \
  -v ccs-openmemory-store:/home/bun/.local/share/openmemory \
  -v ccs-projectmem:/home/bun/.projectmem \
  -v ccs-headroom:/home/bun/.headroom \
  ghcr.io/malys/claude-code-studio:full
```

The image runs as the `bun` user. Credentials are not baked into the image; authenticate the CLIs at runtime using the mechanisms documented by the respective providers.

## What is included

- Claude Code CLI
- OpenAI Codex CLI
- `tmux` for terminal/subscription engine support
- `tokless` configured for Claude Code and Codex
- OpenMemory CLI for Claude Code/Codex session portability
- ProjectMem MCP for project-scoped persistent memory
- Headroom MCP for on-demand context compression and retrieval
- CCS itself, fetched from the upstream `Lexus2016/claude-code-studio` repository

## Self-update

At every container start the entrypoint resolves `CCS_REF` upstream and
reinstalls CCS when it points at a different commit than the running tree
(`/app/.ccs-revision`). Nothing else is touched — the CLIs, plugins and MCP
servers move with the image.

| Variable | Default | Effect |
| --- | --- | --- |
| `CCS_AUTO_UPDATE` | `1` | `0` disables the check entirely |
| `CCS_REPO` | upstream CCS repository | Source to track |
| `CCS_REF` | branch/tag baked at build time | A tag only moves when the tag does |

The new tree is cloned, patched and installed in a temp directory and only then
swapped into `/app`, so a failed clone or install leaves the running version
alone. `/app/data`, `/app/workspace` and `/app/skills` are volumes and are never
part of the swap. The update lives in the container's writable layer: it
survives `restart`, and a `docker compose pull` + recreate replaces it with the
image's own version. Expect the start to take as long as a `bun install` when an
update actually lands.

`scripts/ccs-fetch.sh` builds that tree and is the same script the image build
uses, so a self-updated container and a rebuilt image run identical code.
`sh scripts/test-ccs-fetch.sh` checks it against a throwaway repository.

## Persistent paths

| Path | Purpose |
|---|---|
| `/app/data` | CCS application data and config |
| `/app/workspace` | User workspaces/projects |
| `/app/skills` | CCS skill directory |
| `/home/bun/.claude` | Claude state/auth/skills |
| `/home/bun/.codex` | Codex state/auth/config |
| `/home/bun/.config` | User config used by CLI tooling |
| `/home/bun/.openmemory` | OpenMemory state |
| `/home/bun/.local/share/openmemory` | OpenMemory ledger/runtime state |
| `/home/bun/.projectmem` | ProjectMem project registry |
| `/home/bun/.headroom` | Headroom MCP state and retrieval cache |

ProjectMem and Headroom are added idempotently to the CCS, Codex and user-scope
Claude (`~/.claude.json`) MCP config at container startup, so chat runs and
terminal / `docker exec` sessions reach both servers. Existing entries with the
same names are preserved.

Every directory under `WORKDIR` is registered with ProjectMem (`pjm init
--no-watch`) at startup, so each project has its own memory; a project added
while the container runs needs a restart to be picked up.

Headroom is the opposite: memory is **global** and never per project. It runs in
MCP-only mode (no proxy, dashboard or extra network port), and
`HEADROOM_WORKSPACE_DIR` / `HEADROOM_MEMORY_DB_PATH` pin its store to
`/home/bun/.headroom/memory.db` for every session, so opening a project never
raises a "how should memory be scoped?" question. Headroom still prefers
`<cwd>/.headroom/memory.db` when that file exists, so the entrypoint warns about
any project-local store it finds under `WORKDIR` — delete it to stay global.

## CI/CD

`.github/workflows/publish.yml` publishes multi-architecture images (`linux/amd64` and `linux/arm64`) to GHCR on:

- weekly schedule
- manual `workflow_dispatch`
- `repository_dispatch` event type `ccs-release`
- git version tags pushed to this repository

A release automation in the CCS repository can notify this repository with a `repository_dispatch` payload such as:

```json
{
  "event_type": "ccs-release",
  "client_payload": {
    "ccs_ref": "v7.16.2",
    "version": "7.16.2"
  }
}
```

For that cross-repository dispatch, the caller must have a token with permission to dispatch workflows in this repository. The image workflow itself uses the repository's `GITHUB_TOKEN` only for GHCR publishing.

## Build locally

```bash
docker build \
  --build-arg CCS_REF=main \
  --build-arg CLAUDE_CODE_VERSION=latest \
  --build-arg CODEX_VERSION=latest \
  --build-arg TOKLESS_REF=main \
  --build-arg OPENMEMORY_REF=main \
  --build-arg PROJECTMEM_VERSION=0.3.2 \
  --build-arg HEADROOM_VERSION=0.37.0 \
  -t ccs-full:local .
```

For reproducible releases, replace the rolling refs with immutable upstream tags or commit SHAs.

## Security notes

Authentication and provider credentials are deliberately excluded from the image. Persistent agent directories are volumes so first-run authentication and session state survive container recreation. The Dockerfile runs the application as a non-root user.
