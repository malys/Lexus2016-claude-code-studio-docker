// tmux caps a single command string at ~16 KB (its imsg limit), but CCS builds
// the whole system prompt — AGENTS.md included, up to 64 KB — into the command
// it hands to `tmux new-session`. A project with a large AGENTS.md then fails
// as "failed to start tmux session for interactive engine". Spill the prompt to
// a file so the tmux command stays short and `$(cat ...)` restores it in full.
// Mirrors mcpConfigPath() in claude-interactive.js: content-hashed name, 0600,
// written once, left in tmpdir for the session to re-read on respawn.
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

module.exports = function systemPromptPath(sp) {
  const hash = crypto.createHash('sha256').update(sp).digest('hex').slice(0, 16);
  const p = path.join(os.tmpdir(), `ccs-sp-${hash}.txt`);
  // 0600: the prompt carries project instructions and any studio-side secrets.
  if (!fs.existsSync(p)) fs.writeFileSync(p, sp, { mode: 0o600 });
  return p;
};
