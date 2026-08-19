#!/bin/bash

# -----------------------------------------------------------------------------
# Claude Secure Docker Environment Setup Script
# -----------------------------------------------------------------------------
set -e

echo "🚀 Starting Claude secure Docker environment setup..."

# --- 1. Preserve existing Claude state ---
# Intentionally do NOT remove $HOME/.claude, $HOME/.claude.json, or the
# wrapper binary on re-runs — this script must be safe to re-run for image
# updates without logging the user out or wiping conversation history.

# --- 2. Ensure config exists (idempotent — never overwrites) ---
if [[ ! -d "$HOME/.claude" ]]; then
    echo "📁 Creating $HOME/.claude (first-run only)..."
    mkdir -p "$HOME/.claude"
else
    echo "✅ Preserving existing $HOME/.claude (login & history intact)."
fi

if [[ ! -f "$HOME/.claude.json" ]]; then
    echo "✍️ Writing default config to $HOME/.claude.json (first-run only)..."
    cat <<'EOF' > "$HOME/.claude.json"
{
 "numStartups": 0,
 "theme": "dark",
 "preferredNotifChannel": "auto",
 "verbose": false,
 "editorMode": "normal",
 "autoCompactEnabled": true,
 "hasSeenTasksHint": false,
 "queuedCommandUpHintCount": 0,
 "diffTool": "auto",
 "customApiKeyResponses": {
 "approved": [],
 "rejected": []
 },
 "env": {},
 "tipsHistory": {},
 "memoryUsageCount": 0,
 "promptQueueUseCount": 0,
 "todoFeatureEnabled": true,
 "showExpandedTodos": false,
 "messageIdleNotifThresholdMs": 60000,
 "autoConnectIde": false,
 "autoInstallIdeExtension": true,
 "autocheckpointingEnabled": true,
 "checkpointingShadowRepos": [],
 "fileCheckpointingEnabled": true,
 "cachedStatsigGates": {},
 "cachedDynamicConfigs": {},
 "respectGitignore": true
}
EOF
else
    echo "✅ Preserving existing $HOME/.claude.json."
fi

[[ -f "$HOME/.claude.json.backup" ]] || touch "$HOME/.claude.json.backup"

# --- 3. Build the Docker Image ---
echo "🐳 Building Docker image (claude-secure)..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/Dockerfile" || ! -f "$SCRIPT_DIR/entrypoint.sh" ]]; then
    echo "❌ Error: Dockerfile or entrypoint.sh not found in $SCRIPT_DIR."
    echo "Please run this script from the directory containing those files."
    exit 1
fi

# Build image tagged as 'claude-secure'
cd "$SCRIPT_DIR"
docker build --no-cache --build-arg HTTP_PROXY=http://172.17.0.1:10808 --build-arg HTTPS_PROXY=http://172.17.0.1:10808 -t ghcr.io/hfeizbakhshian/claude-no-leak:latest .

# --- 4. Create wrapper script to run Docker ---
BIN_DIR="$HOME/.local/bin"
SCRIPT_PATH="$BIN_DIR/claude"

echo "📁 Creating executable directory $BIN_DIR (if not exists)..."
mkdir -p "$BIN_DIR"

echo "🧹 Removing old claude alias from $HOME/.bashrc (if any)..."
ALIAS_MARKER_START="# ALIAS_CLAUDE_START"
ALIAS_MARKER_END="# ALIAS_CLAUDE_END"
sed -i "/$ALIAS_MARKER_START/,/$ALIAS_MARKER_END/d" "$HOME/.bashrc"

echo "✍️ Creating executable Docker wrapper script at $SCRIPT_PATH..."
cat <<'WRAPPER' > "$SCRIPT_PATH"
#!/bin/bash
set -e

# Run Claude inside the Docker container
docker run -it --rm \
    --cap-add=NET_ADMIN \
    --add-host=host.docker.internal:host-gateway \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e HOST_PWD="$PWD" \
    -e CLAUDE_EXPECTED_COUNTRY \
    -e CLAUDE_TIMEZONE \
    -e CLAUDE_COUNTRY_RECHECK_SECONDS \
    -v "$PWD:$PWD" \
    -v "$HOME/.claude:/home/claude-user/.claude" \
    -v "$HOME/.claude.json:/home/claude-user/.claude.json" \
    ghcr.io/hfeizbakhshian/claude-no-leak:latest "$@"
WRAPPER

chmod +x "$SCRIPT_PATH"

# --- 5. Add to PATH ---
echo "PATH check for $BIN_DIR..."
PATH_MARKER_START="# LOCAL_BIN_PATH_START"
PATH_MARKER_END="# LOCAL_BIN_PATH_END"
PATH_ADD_BLOCK="export PATH=\"\$HOME/.local/bin:\$PATH\""

if ! grep -q "$PATH_MARKER_START" "$HOME/.bashrc"; then
    echo "   Adding $BIN_DIR to PATH in $HOME/.bashrc..."
    cat <<EOF >> "$HOME/.bashrc"

$PATH_MARKER_START
if [ -d "\$HOME/.local/bin" ] ; then
    $PATH_ADD_BLOCK
fi
$PATH_MARKER_END
EOF
else
    echo "   $BIN_DIR PATH block already exists in .bashrc."
fi

# --- 6. Copy CLAUDE.md into ~/.claude for persistence ---
CLAUDE_MD_SRC="$SCRIPT_DIR/CLAUDE.md"
if [[ -f "$CLAUDE_MD_SRC" ]]; then
    echo "📋 Copying CLAUDE.md to $HOME/.claude/CLAUDE.md..."
    cp "$CLAUDE_MD_SRC" "$HOME/.claude/CLAUDE.md"
else
    echo "⚠️  CLAUDE.md not found at $CLAUDE_MD_SRC — skipping copy."
fi

# --- 7. Finalize ---
echo "✅ Executable wrapper script created and PATH updated."
echo "🎉 Setup successful."
echo "To apply PATH changes, please open a new terminal or run:"
echo "source ~/.bashrc"
