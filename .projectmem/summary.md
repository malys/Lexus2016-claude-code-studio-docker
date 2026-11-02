# projectmem - Lexus2016-claude-code-studio-docker

_Last updated: 2026-11-02_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- [DONE] #legacy_f694 Legacy issue: fix: ignore tokless RTK setup failure in Docker build -> fix: ignore tokless RTK setup failure in Docker build (fixed)
- [DONE] #legacy_f57a Legacy issue: fix(entrypoint): prune orphan CCS worktrees at startup -> fix(entrypoint): prune orphan CCS worktrees at startup (fixed)
- [DONE] #legacy_f18a Legacy issue: fix(entrypoint): cap agent sessions and stop OpenMemory clone chains -> fix(entrypoint): cap agent sessions and stop OpenMemory clone chains (fixed)
- [DONE] #legacy_e87a Legacy issue: fix: build (locally OK) -> fix: build (locally OK) (fixed)
- [DONE] #legacy_dc17 Legacy issue: fix(smoke-test): use supported flags for pjm and headroom checks -> fix(smoke-test): use supported flags for pjm and headroom checks (fixed)
- [DONE] #legacy_d8e0 Legacy issue: fix(build): actually run tokless wiring during docker build -> fix(build): actually run tokless wiring during docker build (fixed)
- [DONE] #legacy_c745 Legacy issue: Fix tokless installation by downloading script to temp file first -> Fix tokless installation by downloading script to temp file first (fixed)
- [DONE] #legacy_bc9f Legacy issue: fix: seed onboarding on bind-mounted config, add node shim -> fix: seed onboarding on bind-mounted config, add node shim (fixed)
- [DONE] #legacy_a504 Legacy issue: fix(build): spill CCS system prompt to a file for tmux -> fix(build): spill CCS system prompt to a file for tmux (fixed)
- [DONE] #legacy_6ed5 Legacy issue: fix: skills share -> fix: skills share (fixed)
- [DONE] #legacy_696d Legacy issue: fix(entrypoint): trust every project directory, not just WORKDIR -> fix(entrypoint): trust every project directory, not just WORKDIR (fixed)
- [DONE] #legacy_4851 Legacy issue: fix: cli arg -> fix: cli arg (fixed)
- [DONE] #legacy_10d1 Legacy issue: fix(entrypoint): support non-root startup -> fix(entrypoint): support non-root startup (fixed)
- [DONE] #legacy_0960 Legacy issue: fix(entrypoint): pre-accept Claude first-run prompts -> fix(entrypoint): pre-accept Claude first-run prompts (fixed)
- [DONE] #0001 After container recreate: tokless integration missing (no context-mode skills in ~/.claude/skills or /app/skills) and new workspace projects never codegraph-indexed; root `docker exec` also leaves root-owned .codegraph dirs [scripts/docker-entrypoint.sh] -> Entrypoint now re-links tokless package skills (~/.claude/skills + /app/skills mirror) and runs a background `codegraph init -y` sweep over unindexed WORKDIR projects; verify.sh pins both. Verified live: 8 ctx-* skills linked and loaded by this session, CFSTracker + nodered-flow-store indexed, both steps idempotent on re-run. [scripts/docker-entrypoint.sh] (fixed)

## Decisions
- Entrypoint seeds ProjectMem+Headroom MCP into ~/.claude.json (user scope) as well as CCS config and Codex, because --mcp-config reaches chat runs only and terminal/docker-exec claude sessions read ~/.claude.json; Headroom stays global (MCP-only mode, one compression store) so only ProjectMem gets a per-project `pjm init` loop over WORKDIR/*. [scripts/docker-entrypoint.sh]
- Entrypoint re-links tokless package skills on every start (named volumes are seeded from the image only while empty, so an older claude-home/claude-skills volume never receives skills a newer image added) and runs a BACKGROUND `codegraph init -y` sweep over WORKDIR/* for projects with no .codegraph (CCS_CODEGRAPH_INDEX=0 disables; backgrounded so a first index of a large repo does not delay server startup) [scripts/docker-entrypoint.sh]
- CCS self-updates at container start: entrypoint compares /app/.ccs-revision against `git ls-remote CCS_REF CCS_REF^{}` (peeled, so a pinned tag does not loop) and, when it moved, rebuilds the tree in /tmp via the shared scripts/ccs-fetch.sh before swapping it into /app, keeping the data/workspace/skills volumes. Opt out with CCS_AUTO_UPDATE=0. The Dockerfile builder calls the same script so image and self-update produce identical code. [scripts/ccs-fetch.sh]
- Headroom stays MCP-only (on-demand compress/retrieve/stats, in-memory store); removed HEADROOM_WORKSPACE_DIR/HEADROOM_MEMORY_DB_PATH, the project-store warning and their verify.sh check — memory is a `headroom proxy` feature, and workspace_dir already defaults to ~/.headroom. tokless Headroom = proxy-only (ANTHROPIC_BASE_URL :8787), unreleased past v0.3.2; adopting it would need the entrypoint to run `headroom proxy` (no systemd in container). [Dockerfile]
- Entrypoint enforces privacy on every start: ~/.claude/settings.json env (NONESSENTIAL_TRAFFIC, TELEMETRY, ERROR_REPORTING, BUG_COMMAND, FEEDBACK_SURVEY = "1") + deny Read(./.env), Read(./secrets/**); ~/.codex/config.toml [history] persistence="none" via awk; verify_privacy warns [ccs] PRIVACY on failure (does not abort). Account training toggles stay manual on claude.ai/chatgpt.com. [scripts/docker-entrypoint.sh]
- tokless wires an explicit TOKLESS_TOOLS list (rtk,caveman,principles,codegraph,context-mode,projectmem) at build and every start. headroom excluded (proxy-only in tokless; image keeps Headroom MCP-only), ponytail excluded (bundled ponytail plugin already injects the rules). ProjectMem now tokless-owned (run-mcp wrapper + SessionStart memory hook); /opt/agent-tools keeps only headroom. [Dockerfile]

## Notes
- feat(entrypoint): prune agent sessions older than retention window
- chore(entrypoint): drop empty session directories after pruning
- New feature: feat(entrypoint): register every workspace project in ProjectMem [.gitignore]
- Merge: feat(entrypoint): seed ProjectMem and Headroom MCP for user-scope Claude
- chore(projectmem): track the project memory store
- gotcha: `docker exec -ti claude-code-studio bash` lands as ROOT with HOME=/home/bun — running tokless/codegraph/claude there writes root-owned files into bun's home and into <project>/.codegraph, which the bun-owned server then reports as "attempt to write a readonly database". Use `docker exec -u bun`; the entrypoint chown -R heals it on the next restart. [scripts/docker-entrypoint.sh]
- feat(entrypoint): update CCS from upstream at container start
- Merge: fix(build): drop no-op tmux system-prompt patch
- gotcha: tokless 1.0.9 `disable --tools headroom` (and a --tools run omitting headroom) reports "unwire failed: claude/headroom" and leaves Codex's fenced "# --- Headroom persistent provider ---" block; entrypoint strips ANTHROPIC_BASE_URL=http://127.0.0.1:8787 and that block itself. Also: tokless's projectmem uv venv used headroom's bundled CPython 3.13 — a build without headroom must still pass `pjm --help` smoke test. [scripts/docker-entrypoint.sh]
- New feature: feat(entrypoint): enforce Claude and Codex privacy settings [scripts/docker-entrypoint.sh]

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
- `.projectmem/AI_INSTRUCTIONS.md`
- `.projectmem/PROJECT_MAP.md`
- `.projectmem/config.toml`
- `.projectmem/issues/legacy_0960-legacy-issue-fix-entrypoint-pre-accept-claude-fi.md`
- `.projectmem/issues/legacy_10d1-legacy-issue-fix-entrypoint-support-non-root-sta.md`
- `.projectmem/issues/legacy_4851-legacy-issue-fix-cli-arg.md`
- `.projectmem/issues/legacy_696d-legacy-issue-fix-entrypoint-trust-every-project.md`
- `.projectmem/issues/legacy_6ed5-legacy-issue-fix-skills-share.md`
- `.projectmem/issues/legacy_a504-legacy-issue-fix-build-spill-ccs-system-prompt-t.md`
- `.projectmem/issues/legacy_bc9f-legacy-issue-fix-seed-onboarding-on-bind-mounted.md`
- `.projectmem/issues/legacy_c745-legacy-issue-fix-tokless-installation-by-downloa.md`

## Open questions
- None logged yet.
