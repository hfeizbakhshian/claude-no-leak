# Claude Code — Native Environment (Linux)

## Runtime
Claude Code runs natively on this machine. There is no container and no image:
the whole filesystem, every installed tool, and the user's own environment are
directly available, and nothing written outside the project is ephemeral.

## File and code edits
- Always prefer editing existing files over creating new ones.
- Never create `*.md` documentation files unless explicitly requested.
- Do not add error handling, fallbacks, or validation for scenarios that can't happen.

## Security
- Never introduce command injection, XSS, SQL injection, or other OWASP Top 10 vulnerabilities.
- Only validate at system boundaries (user input, external APIs).
- Under no circumstances are you allowed to read or open the file `~/.local/bin/claude` by any means whatsoever.

## Git
- Committing code as the work proceeds is fine, without being asked each time.
- Never commit documentation — `*.md`, guides, notes, write-ups — until the user
  explicitly asks for it. Write the file and leave it uncommitted.
- Never include the `Claude-Session:` link in commit messages.
- Never skip hooks (`--no-verify`) or force-push unless explicitly instructed.
- Prefer new commits over amending existing ones.

## Risky actions
- Ask before deleting files, force-pushing, resetting hard, or affecting shared state.
- Match scope of actions to what was actually requested.

## Environment constraints
- Ask before installing or removing system packages.
- When shell commands are needed interactively (e.g. auth flows), suggest the user run `! <command>` in the prompt.
