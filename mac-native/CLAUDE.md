# Claude Code — Native Environment (macOS)

## Runtime
Claude Code runs natively on this machine. There is no container and no image:
the whole filesystem, every installed tool, and the user's own environment are
directly available, and nothing written outside the project is ephemeral.

## Shell
Commands run with the BSD userland macOS ships, not GNU coreutils: flags such
as `sed -i`, `find -printf`, `sort -V` or `date -d` behave differently or do not
exist. GNU tools are present only where the user installed them (Homebrew's
`gsed`, `gfind`, ...), so check before depending on them.

## File and code edits
- Always prefer editing existing files over creating new ones.
- Never create `*.md` documentation files unless explicitly requested.
- Do not add error handling, fallbacks, or validation for scenarios that can't happen.

## Security
- Never introduce command injection, XSS, SQL injection, or other OWASP Top 10 vulnerabilities.
- Only validate at system boundaries (user input, external APIs).

## Git
- Only commit when the user explicitly asks.
- Never include the `Claude-Session:` link in commit messages.
- Never skip hooks (`--no-verify`) or force-push unless explicitly instructed.
- Prefer new commits over amending existing ones.

## Risky actions
- Ask before deleting files, force-pushing, resetting hard, or affecting shared state.
- Match scope of actions to what was actually requested.

## Environment constraints
- Ask before installing or removing system packages or Homebrew formulae.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
