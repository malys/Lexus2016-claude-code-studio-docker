# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-bookworm
ARG CCS_REPO=https://github.com/Lexus2016/claude-code-studio.git
ARG CCS_REF=main

# Keep the agent/tool versions overrideable from CI.
ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG TOKLESS_REF=main
ARG OPENMEMORY_REF=main

# -----------------------------------------------------------------------------
# Builder: fetch and build CCS from the upstream repository.
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS ccs-builder

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

# npm install is used rather than npm ci so the image also works when the
# upstream repository changes lockfile/package-manager details between CCS releases.
RUN npm install --omit=dev

# Copy only the application and its runtime dependencies into the final stage.
# A small manifest is retained for build metadata/debugging.
RUN mkdir -p /out/app \
    && cp -a package.json package-lock.json server.js bin public skills scripts hooks \
          config.example.json auth.js auth-errors.js db-adapter.js claude-cli.js \
          claude-interactive.js claude-ssh.js mcp-ask-user.js mcp-notify.js \
          mcp-set-ui-state.js mcp-task-manager.js mcp-user-interrupt.js \
          rate-limit-utils.js telegram-bot-forum.js telegram-bot-i18n.js \
          telegram-bot.js tunnel-manager.js /out/app/ \
    && cp -a node_modules /out/app/node_modules

# -----------------------------------------------------------------------------
# Runtime
# -----------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION
ARG TOKLESS_REF
ARG OPENMEMORY_REF

ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_ENV=production
ENV PORT=3000
ENV HOST=0.0.0.0
ENV WORKDIR=/app/workspace
ENV HOME=/home/node
ENV PATH=/home/node/.local/bin:/home/node/.bun/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    tmux \
    ripgrep \
    openssh-client \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy the complete CCS runtime tree. The builder already installed production
# dependencies; retaining the upstream layout avoids accidentally omitting a
# runtime module as CCS evolves.
WORKDIR /app
COPY --from=ccs-builder /src/ ./
RUN rm -rf /app/.git /app/.github /app/.planning /app/test /app/electron \
    /app/homebrew-tap /app/build

# Install agent CLIs as the non-root runtime user. npm itself is available in
# the official Node image and the executables are placed in /usr/local/bin.
RUN npm install -g \
      @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
      @openai/codex@${CODEX_VERSION} \
    && npm cache clean --force

# Switch to node before running user-scoped installers.
USER node

# User-scoped CLI/config directories.
RUN mkdir -p \
      /home/node/.local/bin \
      /home/node/.claude/skills \
      /home/node/.codex \
      /home/node/.bun \
      /home/node/.config \
      /home/node/.cache \
      /home/node/.openmemory \
      /home/node/.local/share/openmemory \
      /app/data \
      /app/workspace \
      /app/skills \
    && chown -R node:node \
      /home/node \
      /app/data \
      /app/workspace \
      /app/skills

USER node

# tokless installer: upstream documents the curl installer and automatic agent
# detection/selection. Only Claude and Codex are installed in this image.
ARG TOKLESS_REF
RUN curl -fsSL "https://raw.githubusercontent.com/HoangP8/tokless/${TOKLESS_REF}/scripts/install.sh" | bash \
    && tokless --agents claude,codex

# OpenMemory is currently distributed as a source checkout and runs under Bun.
# Install Bun, clone the selected OpenMemory ref, install production runtime
# dependencies, and create the same launcher shape as the upstream installer.
ARG OPENMEMORY_REF
RUN curl -fsSL https://bun.sh/install | bash \
    && git clone --depth 1 --branch "${OPENMEMORY_REF}" \
         https://github.com/mem0ai/openmemory.git \
         /home/node/.local/share/openmemory/src \
    && cd /home/node/.local/share/openmemory/src/cli \
    && /home/node/.bun/bin/bun install --production \
    && printf '%s\n' \
         '#!/bin/sh' \
         '# Managed by the CCS full image.' \
         'cd "$HOME/.local/share/openmemory/src/cli"' \
         'exec "$HOME/.bun/bin/bun" src/cli.ts "$@"' \
         > /home/node/.local/bin/openmemory \
    && chmod 0755 /home/node/.local/bin/openmemory

# CCS scans /app/skills while Claude Code scans ~/.claude/skills. Mirror any
# tokless-generated Claude skills so the CCS-level system prompt sees them too.
RUN if [ -d /home/node/.claude/skills ]; then \
      cp -a /home/node/.claude/skills/. /app/skills/ 2>/dev/null || true; \
    fi

# Seed persistent directories and a conventional config location. CCS's own
# compose file redirects config/env persistence to /app/data.
RUN touch /app/data/config.json \
    && chmod 600 /app/data/config.json \
    && touch /home/node/.claude/.keep /home/node/.codex/.keep

# Build-time smoke test. Version commands are allowed to fail if an upstream
# CLI changes its version flag; command presence is the hard requirement.
RUN command -v claude \
    && command -v codex \
    && command -v tokless \
    && command -v openmemory \
    && command -v tmux \
    && test -f /app/server.js

VOLUME ["/app/data", "/app/workspace", "/app/skills", "/home/node/.claude", "/home/node/.codex", "/home/node/.config", "/home/node/.openmemory", "/home/node/.local/share/openmemory"]

EXPOSE 3000

CMD ["node", "server.js"]
