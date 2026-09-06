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
  -v ccs-claude:/home/node/.claude \
  -v ccs-codex:/home/node/.codex \
  -v ccs-openmemory:/home/node/.openmemory \
  -v ccs-openmemory-store:/home/node/.local/share/openmemory \
  ghcr.io/<owner>/claude-code-studio:full
```

The image runs as the `node` user. Credentials are not baked into the image; authenticate the CLIs at runtime using the mechanisms documented by the respective providers.

## What is included

- Claude Code CLI
- OpenAI Codex CLI
- `tmux` for terminal/subscription engine support
- `tokless` configured for Claude Code and Codex
- OpenMemory CLI for Claude Code/Codex session portability
- CCS itself, fetched from the upstream `Lexus2016/claude-code-studio` repository

## Persistent paths

| Path | Purpose |
|---|---|
| `/app/data` | CCS application data and config |
| `/app/workspace` | User workspaces/projects |
| `/app/skills` | CCS skill directory |
| `/home/node/.claude` | Claude state/auth/skills |
| `/home/node/.codex` | Codex state/auth/config |
| `/home/node/.config` | User config used by CLI tooling |
| `/home/node/.openmemory` | OpenMemory state |
| `/home/node/.local/share/openmemory` | OpenMemory source/runtime data |

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
  -t ccs-full:local .
```

For reproducible releases, replace the rolling refs with immutable upstream tags or commit SHAs.

## Security notes

Authentication and provider credentials are deliberately excluded from the image. Persistent agent directories are volumes so first-run authentication and session state survive container recreation. The Dockerfile runs the application as a non-root user.
