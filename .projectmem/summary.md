# projectmem - Lexus2016-claude-code-studio-docker

_Last updated: 2026-09-11_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- [DONE] #legacy_f694 Legacy issue: fix: ignore tokless RTK setup failure in Docker build -> fix: ignore tokless RTK setup failure in Docker build (fixed)
- [DONE] #legacy_e87a Legacy issue: fix: build (locally OK) -> fix: build (locally OK) (fixed)
- [DONE] #legacy_dc17 Legacy issue: fix(smoke-test): use supported flags for pjm and headroom checks -> fix(smoke-test): use supported flags for pjm and headroom checks (fixed)
- [DONE] #legacy_c745 Legacy issue: Fix tokless installation by downloading script to temp file first -> Fix tokless installation by downloading script to temp file first (fixed)
- [DONE] #legacy_bc9f Legacy issue: fix: seed onboarding on bind-mounted config, add node shim -> fix: seed onboarding on bind-mounted config, add node shim (fixed)
- [DONE] #legacy_a504 Legacy issue: fix(build): spill CCS system prompt to a file for tmux -> fix(build): spill CCS system prompt to a file for tmux (fixed)
- [DONE] #legacy_6ed5 Legacy issue: fix: skills share -> fix: skills share (fixed)
- [DONE] #legacy_696d Legacy issue: fix(entrypoint): trust every project directory, not just WORKDIR -> fix(entrypoint): trust every project directory, not just WORKDIR (fixed)
- [DONE] #legacy_4851 Legacy issue: fix: cli arg -> fix: cli arg (fixed)
- [DONE] #legacy_10d1 Legacy issue: fix(entrypoint): support non-root startup -> fix(entrypoint): support non-root startup (fixed)
- [DONE] #legacy_0960 Legacy issue: fix(entrypoint): pre-accept Claude first-run prompts -> fix(entrypoint): pre-accept Claude first-run prompts (fixed)

## Decisions
- Entrypoint seeds ProjectMem+Headroom MCP into ~/.claude.json (user scope) as well as CCS config and Codex, because --mcp-config reaches chat runs only and terminal/docker-exec claude sessions read ~/.claude.json; Headroom stays global (MCP-only mode, one compression store) so only ProjectMem gets a per-project `pjm init` loop over WORKDIR/*. [scripts/docker-entrypoint.sh]

## Notes
- publish on push
- bun owner on app
- update docker image name
- add message
- feat(docker): bundle ponytail, karpathy and caveman plugins
- feat(docker): bundle ProjectMem and Headroom MCP servers
- feat(entrypoint): prune agent sessions older than retention window
- chore(entrypoint): drop empty session directories after pruning
- New feature: feat(entrypoint): register every workspace project in ProjectMem [.gitignore]
- Merge: feat(entrypoint): seed ProjectMem and Headroom MCP for user-scope Claude

## Key files
- `Dockerfile`
- `docker-compose.yml`
- `README.md`
- `.github/workflows/publish.yml`
- `.gitignore`
- `scripts/docker-entrypoint.sh`
- `scripts/verify.sh`
- `patches/ccs-sp-file.js`
- `/.claude.json`

## Open questions
- None logged yet.
