# projectmem - session-mtxaksn4ihdltq

_Last updated: 2026-09-11_

## Project purpose
Replace this placeholder with a concise description of what this project does, who it serves, and the main technologies or runtime assumptions.

## Recent issues
- No issues logged yet.

## Decisions
- CCS self-updates at container start: entrypoint compares /app/.ccs-revision against `git ls-remote CCS_REF CCS_REF^{}` (peeled, so a pinned tag does not loop) and, when it moved, rebuilds the tree in /tmp via the shared scripts/ccs-fetch.sh before swapping it into /app, keeping the data/workspace/skills volumes. Opt out with CCS_AUTO_UPDATE=0. The Dockerfile builder calls the same script so image and self-update produce identical code. [scripts/ccs-fetch.sh]

## Notes
- No notes logged yet.

## Key files
- `/app/.ccs`
- `scripts/ccs-fetch.sh`

## Open questions
- None logged yet.
