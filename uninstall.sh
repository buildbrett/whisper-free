#!/usr/bin/env bash
set -euo pipefail

PLIST_NAME="com.local.whisper-free"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$INSTALL_DIR/.venv"

echo "Uninstalling Whisper Free..."

# Stop and remove LaunchAgent
if launchctl list "$PLIST_NAME" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    echo "LaunchAgent stopped."
fi

if [[ -f "$PLIST_PATH" ]]; then
    rm "$PLIST_PATH"
    echo "LaunchAgent plist removed."
fi

# Remove Karabiner rule
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"
if [[ -f "$KARABINER_CONFIG" ]] && [[ -d "$VENV_DIR" ]]; then
    "$VENV_DIR/bin/python" - "$KARABINER_CONFIG" <<'PYEOF'
import json, sys

config_path = sys.argv[1]
with open(config_path) as f:
    config = json.load(f)

removed = False
for profile in config.get("profiles", []):
    rules = profile.get("complex_modifications", {}).get("rules", [])
    before = len(rules)
    rules[:] = [r for r in rules if "Whisper" not in r.get("description", "")]
    if len(rules) < before:
        removed = True

if removed:
    with open(config_path, "w") as f:
        json.dump(config, f, indent=4, ensure_ascii=False)
    print("Karabiner hotkey rule removed.")
else:
    print("No Karabiner hotkey rule found.")
PYEOF
fi

# Clean up sockets
rm -f /tmp/whisper_free.sock /tmp/whisper_overlay.sock

echo ""
echo "Uninstall complete."
echo "The project files are still in: $INSTALL_DIR"
echo "To fully remove, delete that directory and the .venv inside it."
