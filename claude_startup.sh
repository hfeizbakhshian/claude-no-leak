#!/bin/bash

# -----------------------------------------------------------------------------
# Claude Docker Secure Environment Setup Script
# This script will exit immediately if any command fails.
# -----------------------------------------------------------------------------
set -e

# Variable to track if a reboot is needed
REBOOT_NEEDED=0

echo "🚀 Starting Claude secure environment setup..."

# --- 1. Remove previous npm version ---
echo "🧹 Cleaning up previous @anthropic-ai/claude-code (if any)..."
if command -v npm &> /dev/null; then
    sudo npm uninstall -g @anthropic-ai/claude-code || true
else
    echo "   (npm not found, skipping this step.)"
fi

# --- 2. Remove .claude* files and directories ---
echo "🧹 Cleaning up .claude* files and directories from Home..."
find "$HOME" -depth -name ".claude*" -exec rm -rf {} +

# --- 3. Download and install Docker (if needed) ---
if ! command -v docker &> /dev/null; then
    echo "🐳 Docker not found. Downloading Docker install script..."
    curl -fsSL https://get.docker.com -o install-docker.sh

    echo "🛠️ Running Docker install script (requires sudo)..."
    sudo sh ./install-docker.sh

    echo "🗑️ Removing Docker install script..."
    rm ./install-docker.sh
    
    echo "✅ Docker installed successfully."
else
    echo "✅ Docker is already installed. Skipping."
fi

# --- 4. Add current user to the docker group (if needed) ---
if ! id -nG "$USER" | grep -qw "docker"; then
    echo "👥 Adding user $USER to the docker group..."
    sudo usermod -aG docker "$USER"
    REBOOT_NEEDED=1 # Set flag for reboot
else
    echo "✅ User $USER is already in the docker group."
fi

# --- 5. Pull the Docker image ---
echo "📥 Pulling image ghcr.io/hfeizbakhshian/claude-no-leak:latest..."
# 'sudo' is necessary here because the current session
# doesn't have permissions yet if the user was just added.
sudo docker pull ghcr.io/hfeizbakhshian/claude-no-leak:latest

# --- 6. Create .claude directory and default config ---
echo "📁 Creating directory $HOME/.claude for persistence..."
mkdir -p "$HOME/.claude"

echo "✍️ Writing default config to $HOME/.claude.json..."
# Use 'EOF' to prevent variable expansion
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

touch "$HOME/.claude.json.backup"

# --- 7. Create Executable Script (Replaces Alias) ---

BIN_DIR="$HOME/.local/bin"
SCRIPT_PATH="$BIN_DIR/claude"

echo "📁 Creating executable directory $BIN_DIR (if not exists)..."
mkdir -p "$BIN_DIR"

echo "🧹 Removing old claude alias from $HOME/.bashrc (if any)..."
ALIAS_MARKER_START="# ALIAS_CLAUDE_START"
ALIAS_MARKER_END="# ALIAS_CLAUDE_END"
sed -i "/$ALIAS_MARKER_START/,/$ALIAS_MARKER_END/d" "$HOME/.bashrc"

echo "✍️ Creating executable script at $SCRIPT_PATH..."
# Use 'EOF' in quotes to prevent variable expansion *now*.
# We want $PWD, $USER, etc. to be expanded when the 'claude' script is run.
cat <<'EOF' > "$SCRIPT_PATH"
#!/bin/bash
set -e

# Get the base name of the current directory
CURRENT_DIR_NAME=$(basename "$PWD")

docker run --rm -it \
  --cap-add=NET_ADMIN \
  --add-host=host.docker.internal:host-gateway \
  -e HOST_UID=$(id -u) \
  -e HOST_GID=$(id -g) \
  -v "$PWD:/app/$CURRENT_DIR_NAME" \
  -w "/app/$CURRENT_DIR_NAME" \
  -v "$HOME/.claude:/home/claude-user/.claude" \
  -v "$HOME/.claude.json:/home/claude-user/.claude.json" \
  -v "$HOME/.claude.json.backup:/home/claude-user/.claude.json.backup" \
  ghcr.io/hfeizbakhshian/claude-no-leak:latest "$@"
EOF

echo "🔒 Setting executable permissions for $SCRIPT_PATH..."
chmod +x "$SCRIPT_PATH"

echo "PATH check for $BIN_DIR..."
PATH_MARKER_START="# LOCAL_BIN_PATH_START"
PATH_MARKER_END="# LOCAL_BIN_PATH_END"
PATH_ADD_BLOCK="export PATH=\"\$HOME/.local/bin:\$PATH\""

# Check if the block already exists
if ! grep -q "$PATH_MARKER_START" "$HOME/.bashrc"; then
    echo "   Adding $BIN_DIR to PATH in $HOME/.bashrc..."
    # Add new block to the end of the file
    cat <<EOF >> "$HOME/.bashrc"

$PATH_MARKER_START
# Add .local/bin to PATH
if [ -d "\$HOME/.local/bin" ] ; then
    $PATH_ADD_BLOCK
fi
$PATH_MARKER_END
EOF
else
    echo "   $BIN_DIR PATH block already exists in .bashrc."
fi

echo "✅ Executable script created and PATH updated."

# --- 8. Finalize, Self-Delete, and Reboot (if needed) ---
if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo "🎉 Installation successful."
    echo "Your user was added to the docker group. The system must reboot for changes to take effect."
    echo "🛑 System will reboot in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    
    echo "🧹 Cleaning up setup script..."
    rm -- "$0"
    
    sudo reboot
else
    echo "🎉 Setup successful."
    echo "✅ No reboot needed."
    echo "To apply PATH changes, please open a new terminal or run:"
    echo "source ~/.bashrc"
    
    echo "🧹 Cleaning up setup script..."
    rm -- "$0"
fi
