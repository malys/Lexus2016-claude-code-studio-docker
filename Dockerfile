# syntax=docker/dockerfile:1.7

ARG BUN_IMAGE=oven/bun:1-debian
ARG CCS_REPO=https://github.com/Lexus2016/claude-code-studio.git
ARG CCS_REF=main

# Keep the agent/tool versions overrideable from CI.
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG TOKLESS_REF=main
ARG OPENMEMORY_REF=main
ARG PROJECTMEM_VERSION=0.3.2
ARG HEADROOM_VERSION=0.37.0

# -----------------------------------------------------------------------------
# Builder: fetch and build CCS from the upstream repository.
# -----------------------------------------------------------------------------
FROM ${BUN_IMAGE} AS ccs-builder

ARG CCS_REPO
ARG CCS_REF

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    make \
    g++ \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch "${CCS_REF}" "${CCS_REPO}" . \
    && git rev-parse HEAD > /ccs-revision

# tmux caps a single command string at ~16 KB (its imsg limit), but CCS builds
# the whole system prompt into the command it hands to `tmux new-session`, and
# that prompt carries the project's AGENTS.md (up to 64 KB). A project with a
# large AGENTS.md therefore never starts and CCS only reports "failed to start
# tmux session for interactive engine". Spill the prompt to a file instead.
COPY patches/ccs-sp-file.js /src/ccs-sp-file.js
RUN grep -q 'innerCmd += ` --append-system-prompt ${shq(sp)}`' claude-interactive.js \
    && sed -i 's|innerCmd += ` --append-system-prompt ${shq(sp)}`|innerCmd += ` --append-system-prompt "$(cat ${shq(require("./ccs-sp-file.js")(sp))})"`|' claude-interactive.js

# npm install is used rather than npm ci so the image also works when the
# upstream repository changes lockfile/package-manager details between CCS releases.
RUN bun install --omit=dev

# Copy only the application and its runtime dependencies into the final stage.
# A small manifest is retained for build metadata/debugging.
RUN mkdir -p /out/app \
    && cp -a package.json package-lock.json server.js bin public skills scripts hooks \
          config.example.json auth.js auth-errors.js db-adapter.js claude-cli.js \
          claude-interactive.js claude-ssh.js mcp-ask-user.js mcp-notify.js \
          mcp-set-ui-state.js mcp-task-manager.js mcp-user-interrupt.js \
          rate-limit-utils.js telegram-bot-forum.js telegram-bot-i18n.js \
          telegram-bot.js tunnel-manager.js /out/app/ \
    && cp -a node_modules /out/app/bun_modules

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
FROM ${BUN_IMAGE} AS runtime

ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION
ARG TOKLESS_REF
ARG OPENMEMORY_REF
ARG PROJECTMEM_VERSION
ARG HEADROOM_VERSION

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0
ENV WORKDIR=/app/workspace
ENV CCS_CONFIG_PATH=/app/data/config.json
ENV CCS_ENV_PATH=/app/data/.env
ENV HOME=/home/bun
ENV PATH=/home/bun/.local/bin:/home/bun/.bun/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    tmux \
    ripgrep \
      openssh-client \
      procps \
      gosu \
      python3 \
      python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Copy the complete CCS runtime tree. The builder already installed production
# dependencies; retaining the upstream layout avoids accidentally omitting a
# runtime module as CCS evolves.
WORKDIR /app
COPY --from=ccs-builder /src/ ./
RUN rm -rf /app/.git /app/.github /app/.planning /app/test /app/electron \
    /app/homebrew-tap /app/build

# Install agent CLIs as the non-root runtime user. npm itself is available in
# the Bun image and the executables are placed in /usr/local/bin.
RUN bun install -g \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
      @openai/codex@${CODEX_VERSION}

# Plugin hooks and `#!/usr/bin/env node` shebangs (codex's launcher among them)
# call `node`, which the Bun image does not ship. Bun answers under its
# Node-compatibility mode; a real node is only needed for native addons.
RUN ln -s /usr/local/bin/bun /usr/local/bin/node

# Local stdio MCP servers. Keep them in an image-owned venv so persistent
# user config volumes cannot hide or replace their runtimes.
RUN python3 -m venv /opt/agent-tools \
    && /opt/agent-tools/bin/pip install --no-cache-dir \
         "projectmem==${PROJECTMEM_VERSION}" \
         "headroom-ai[mcp]==${HEADROOM_VERSION}"


# Prepare user-scoped directories while still root so ownership can be set.
RUN mkdir -p \
      /home/bun/.local/bin \
      /home/bun/.local/lib \
      /home/bun/.claude/skills \
      /home/bun/.codex \
      /home/bun/.bun \
      /home/bun/.config \
      /home/bun/.cache \
      /home/bun/.openmemory \
      /home/bun/.local/share/openmemory \
      /home/bun/.projectmem \
      /home/bun/.headroom \
      /app/data \
      /app/workspace \
      /app/skills \
    && chown -R bun:bun \
      /home/bun \
      /app/

# Switch to bun before running user-scoped installers.
USER bun

# tokless installer: upstream documents the curl installer and automatic agent
# detection/selection. Only Claude and Codex are installed in this image.
# Download to temp file first to provide better error diagnostics.
# Note: RTK setup failures are ignored (|| true) as RTK is optional in container
# environments and all required agents are still installed and functional.
ARG TOKLESS_REF
RUN curl -fsSL -o /tmp/install.sh "https://raw.githubusercontent.com/HoangP8/tokless/${TOKLESS_REF}/scripts/install.sh" \
    && bash /tmp/install.sh \
    && tokless --agents claude,codex --yes || true \
    && rm -f /tmp/install.sh

# tokless's installer skips a TTY-dependent setup step in an unattended
# `docker build` (it logs "/dev/tty: No such device or address"), so skills
# bundled inside the packages it installs — e.g. context-mode's ctx-search,
# ctx-index, etc. — are left under node_modules and never linked into
# ~/.claude/skills, where Claude Code (and the mirror step below) look for
# them. Link them in ourselves.
RUN for pkg_skills in /home/bun/.local/lib/node_modules/*/skills/*; do \
      [ -d "$pkg_skills" ] || continue; \
      ln -s "$pkg_skills" "/home/bun/.claude/skills/$(basename "$pkg_skills")"; \
    done 2>/dev/null || true

# Claude Code plugins bundled into the image. The CLI clones marketplaces over
# SSH first and falls back to HTTPS, which is what happens here (no keys).
RUN claude plugin marketplace add DietrichGebert/ponytail \
    && claude plugin install ponytail@ponytail --yes \
    && claude plugin marketplace add forrestchang/andrej-karpathy-skills \
    && claude plugin install andrej-karpathy-skills@karpathy-skills --yes \
    && claude plugin marketplace add JuliusBrussee/caveman \
    && claude plugin install caveman@caveman --yes

# The same three plugins for Codex, which keeps its own marketplace snapshots
# and plugin cache under /home/bun/.codex.
RUN codex plugin marketplace add DietrichGebert/ponytail \
    && codex plugin add ponytail@ponytail \
    && codex plugin marketplace add forrestchang/andrej-karpathy-skills \
    && codex plugin add andrej-karpathy-skills@karpathy-skills \
    && codex plugin marketplace add JuliusBrussee/caveman \
    && codex plugin add caveman@caveman

# OpenMemory is currently distributed as a source checkout and runs under Bun.
# Install Bun, clone the selected OpenMemory ref, install production runtime
# dependencies, and create the same launcher shape as the upstream installer.
ARG OPENMEMORY_REF
RUN git clone --depth 1 --branch "${OPENMEMORY_REF}" \
         https://github.com/mem0ai/openmemory.git \
         /home/bun/.local/lib/openmemory/src \
    && cd /home/bun/.local/lib/openmemory/src/cli \
    && bun install --production \
    && printf '%s\n' \
         '#!/bin/sh' \
         '# Managed by the CCS full image.' \
         'cd "$HOME/.local/lib/openmemory/src/cli"' \
         'exec /usr/local/bin/bun src/cli.ts "$@"' \
         > /home/bun/.local/bin/openmemory \
    && chmod 0755 /home/bun/.local/bin/openmemory \
    && bun pm cache rm

# CCS scans /app/skills while Claude Code scans ~/.claude/skills. Mirror any
# tokless-generated Claude skills so the CCS-level system prompt sees them too.
RUN if [ -d /home/bun/.claude/skills ]; then \
      cp -a /home/bun/.claude/skills/. /app/skills/ 2>/dev/null || true; \
    fi

# Seed persistent directories and a conventional config location. CCS's own
# compose file redirects config/env persistence to /app/data.
RUN touch /app/data/config.json \
    && chmod 600 /app/data/config.json \
    && touch /home/bun/.claude/.keep /home/bun/.codex/.keep

# Build-time smoke test. Version commands are allowed to fail if an upstream
# CLI changes its help output; command presence is the hard requirement.
RUN command -v claude \
    && command -v codex \
    && command -v tokless \
    && command -v openmemory \
    && command -v tmux \
    && /opt/agent-tools/bin/pjm --help >/dev/null \
    && /opt/agent-tools/bin/headroom --version \
    && test -f /app/server.js

VOLUME ["/app/data", "/app/workspace", "/app/skills", "/home/bun/.claude", "/home/bun/.codex", "/home/bun/.config", "/home/bun/.openmemory", "/home/bun/.local/share/openmemory", "/home/bun/.projectmem", "/home/bun/.headroom"]

EXPOSE 3000

# The container starts as root so the entrypoint can fix ownership of bind-mounted
# host volumes (Docker creates missing bind-mount dirs as root) before dropping to
# bun via gosu. USER bun above only scoped the preceding build-time RUN steps.
USER root

COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["bun", "server.js"]
