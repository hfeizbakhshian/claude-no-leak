# claude-no-leak

Setup scenarios that run Claude Code with every outbound connection forced
through a local proxy, so a request that ignores the proxy reaches nothing.

## Layout
One directory per scenario, each self-contained:

- `docker/` — Claude Code inside a container; kill switch via iptables, needs `--cap-add=NET_ADMIN`.
- `linux-native/` — the native release on a Linux host; kill switch via a systemd scope that permits loopback only.
- `windows-native/` — the native release on Windows; kill switch via an outbound Windows Firewall block on the release binary.

## Working in this repo
- The `CLAUDE.md` inside each scenario directory is a **deliverable**, not
  instructions for this repo: the setup script installs it on the target
  machine as `~/.claude/CLAUDE.md`. It describes the environment Claude will
  run in, so keep it self-contained.
- Each setup script carries its own copy of that file inline. Change the two
  copies together.
- Scenarios share no files. Duplication between directories is deliberate —
  each one has to work on a machine that has only that directory.
