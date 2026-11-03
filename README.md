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
ghcr.io/<owner>/claude-code-studio:full-v7.18.3
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

GitHub: set `GH_TOKEN` (add `-e GH_TOKEN=...`, or put it in `.env` for Compose). `gh` reads it directly, and the image's git credential helper reuses it for `git clone/push` over `https://github.com`. Prefer a fine-grained token limited to the repositories the agents may touch.

## What is included

- Claude Code CLI
- OpenAI Codex CLI
- `tmux` for terminal/subscription engine support
- GitHub CLI (`gh`) and `sqlite3`
- `tokless` configured for Claude Code and Codex, with an explicit tool list (`TOKLESS_TOOLS`)
- OpenMemory CLI for Claude Code/Codex session portability
- ProjectMem MCP for project-scoped persistent memory (installed and wired by tokless)
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

The new tree is cloned and installed in a temp directory and only then
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
| `/home/bun/.headroom` | Headroom MCP session stats (the compression store is in memory) |

ProjectMem and Headroom are added idempotently to the CCS, Codex and user-scope
Claude (`~/.claude.json`) MCP config at container startup, so chat runs and
terminal / `docker exec` sessions reach both servers. Existing entries with the
same names are preserved, except the ProjectMem entry of earlier images
(`/opt/agent-tools/bin/python`), whose runtime no longer exists and is replaced.

tokless wires only the tools in `TOKLESS_TOOLS` (default
`rtk,caveman,principles,codegraph,context-mode,projectmem`), at build and on
every start. `headroom` is left out because its tokless integration is the
proxy (see below); `ponytail` is left out because the bundled ponytail plugin
already injects the same rules, and two copies would double the per-session
token cost. tokless owns ProjectMem: it injects the project memory at session
start (`SessionStart` hook) and exposes only its write tools.

Every directory under `WORKDIR` is registered with ProjectMem (`pjm init
--no-watch`) at startup, so each project has its own memory; a project added
while the container runs needs a restart to be picked up.

Every directory under `WORKDIR` is also indexed by CodeGraph (`codegraph init
-y`) at startup when it has no `.codegraph/` yet, so a project added after the
image was built is reachable by the `codegraph_explore` MCP tool instead of
silently falling back to grep. The sweep runs in the background — a first index
of a large repo takes minutes and must not delay the server — and it skips any
project that is already indexed. Set `CCS_CODEGRAPH_INDEX=0` to disable it.

`CCS_AGENT_RULES` pins instructions every Claude and Codex session must get
(for example "no heavy builds or test suites on this host"). At each start it
is written at the top of `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, between
`<!-- ccs-agent-rules:begin -->` / `:end -->` markers. A rule added by hand at the end of those
files does not last: the tokless wiring that runs at startup rewrites everything
below its own block. Unset the variable to remove the pinned block.

The tokless-installed package skills (context-mode's `ctx-search`, `ctx-index`,
`ctx-doctor`, …) are re-linked into `/home/bun/.claude/skills` and mirrored into
`/app/skills` on every start. They are baked into the image, but both of those
paths are **named volumes**, and Docker seeds a named volume from the image only
while the volume is still EMPTY: a volume created by an earlier image keeps its
old content forever, so skills added by a newer image would never show up. The
symptom is "tokless is no longer installed" on a container recreated against an
updated image, even though `tokless` itself reports every tool green — the
binary and its MCP servers live in an image layer and are unaffected.

> **Use `docker exec -u bun`, not a root shell.** The container starts as root
> so the entrypoint can fix bind-mount ownership, so `docker exec -ti
> claude-code-studio bash` lands you as **root with `HOME=/home/bun`**. Anything
> run there — `tokless`, `codegraph`, `claude` — writes root-owned files into
> the `bun` user's home and into project directories; the server then runs as
> `bun` and cannot write them. A root-owned `<project>/.codegraph` reports
> `attempt to write a readonly database` and the project looks un-indexed. The
> entrypoint's `chown -R` repairs it on the next container restart.

Headroom runs in **MCP-only** mode: no proxy, dashboard or extra network port,
and no Headroom memory (that feature belongs to `headroom proxy`). It offers
on-demand `headroom_compress` / `headroom_retrieve` / `headroom_stats` only;
nothing is compressed automatically, and a compressed hash is retrievable only
within the MCP process that produced it. This differs from tokless, whose
Headroom support is proxy-only via `ANTHROPIC_BASE_URL=http://127.0.0.1:8787`
and deliberately refuses MCP wiring. Volumes from an image that let tokless wire
that proxy are cleaned at startup: the entrypoint removes exactly that
`ANTHROPIC_BASE_URL` value from `~/.claude/settings.json` and the fenced
`# --- Headroom persistent provider ---` block from `~/.codex/config.toml`
(`tokless disable --tools headroom` does not remove them reliably as of 1.0.9).

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
    "ccs_ref": "v7.18.3",
    "version": "7.18.3"
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
  --build-arg HEADROOM_VERSION=0.37.0 \
  -t ccs-full:local .
```

For reproducible releases, replace the rolling refs with immutable upstream tags or commit SHAs.

## Security notes

Authentication and provider credentials are deliberately excluded from the image. Persistent agent directories are volumes so first-run authentication and session state survive container recreation. The Dockerfile runs the application as a non-root user.
