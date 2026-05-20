# Claude Code — Docker Environment

## Runtime
Claude Code runs inside a Docker container (Ubuntu 22.04). It has **no access to the host machine** — only what is installed in the container image is available.

## Available tools
- `curl` — HTTP requests, downloads
- `git` — version control
- `grep` — text search
- `iproute2`, `iptables` — network configuration
- `dnsutils` — DNS lookups
- `proxychains-ng`, `privoxy` — proxy tools
- `gosu` — privilege helper
- `ca-certificates`, `gnupg`, `tzdata` — base system utilities

## What is NOT available
No `java`, no `python`, no `node`, no `unzip`, no `gradle`, no `apt` (do not attempt to install packages).

## Persistence
- `/app/<project-dir>` is volume-mounted to the host — **always write important files here**
- `~/.claude` is volume-mounted to the host — settings and memory persist
- Everything else (home dir, tmp, etc.) is ephemeral and lost on container restart

---

## File and code edits
- Always prefer editing existing files over creating new ones.
- Never create `*.md` documentation files unless explicitly requested.
- Do not add error handling, fallbacks, or validation for scenarios that can't happen.

## Security
- Never introduce command injection, XSS, SQL injection, or other OWASP Top 10 vulnerabilities.
- Only validate at system boundaries (user input, external APIs).

## Git
- Only commit when the user explicitly asks.
- Never skip hooks (`--no-verify`) or force-push unless explicitly instructed.
- Prefer new commits over amending existing ones.

## Risky actions
- Ask before deleting files, force-pushing, resetting hard, or affecting shared state.
- Match scope of actions to what was actually requested.

## Environment constraints
- This container has no internet access except through the configured proxy.
- Do not attempt to install system packages — work with what is available.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
