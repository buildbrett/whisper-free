#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.local.whisper-free"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
VENV_DIR="$INSTALL_DIR/.venv"

echo "Whisper Free — Push-to-talk voice-to-text for macOS"
echo "Install directory: $INSTALL_DIR"
echo ""

# --- Prerequisites ---

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: macOS required."
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Error: Apple Silicon Mac required (for MLX acceleration)."
    exit 1
fi

PYTHON=""
for candidate in python3.14 python3.13 python3.12 python3; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$(command -v "$candidate")"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "Error: Python 3 not found. Install with: brew install python"
    exit 1
fi
echo "Using Python: $PYTHON ($("$PYTHON" --version 2>&1))"

# --- Python environment ---

echo ""
echo "Setting up Python environment..."
if [[ ! -d "$VENV_DIR" ]]; then
    "$PYTHON" -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --upgrade pip -q
"$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q
echo "Python dependencies installed."

# --- LaunchAgent ---

echo ""
echo "Installing LaunchAgent..."

if launchctl list "$PLIST_NAME" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
fi

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>

    <key>ProgramArguments</key>
    <array>
        <string>$VENV_DIR/bin/python</string>
        <string>$INSTALL_DIR/stt.py</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/stt-launchd.log</string>

    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/stt-launchd.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "LaunchAgent installed and started."

# --- Karabiner ---

echo ""
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"

if [[ -f "$KARABINER_CONFIG" ]]; then
    "$VENV_DIR/bin/python" - "$KARABINER_CONFIG" "$INSTALL_DIR" <<'PYEOF'
import json, sys

config_path, install_dir = sys.argv[1], sys.argv[2]

with open(config_path) as f:
    config = json.load(f)

new_rule = {
    "description": "Globe key: push-to-talk Whisper Free",
    "manipulators": [{
        "type": "basic",
        "from": {"key_code": "fn", "modifiers": {"optional": []}},
        "to": [{"shell_command": f"{install_dir}/stt-send.sh start"}],
        "to_after_key_up": [{"shell_command": f"{install_dir}/stt-send.sh stop"}],
    }],
}

for profile in config.get("profiles", []):
    rules = profile.setdefault("complex_modifications", {}).setdefault("rules", [])
    # Remove any existing Whisper Free rule
    rules[:] = [r for r in rules if "Whisper" not in r.get("description", "")]
    rules.append(new_rule)
    break  # first profile only

with open(config_path, "w") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)

print("Karabiner hotkey configured (Globe key → push-to-talk).")
PYEOF
else
    echo "Karabiner config not found. Install Karabiner-Elements for hotkey support:"
    echo "  https://karabiner-elements.pqrs.org/"
    echo ""
    echo "After installing, re-run this script to configure the hotkey."
fi

# --- Done ---

echo ""
echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "You may need to grant permissions in System Settings > Privacy & Security:"
echo "  - Microphone: allow Terminal (or Python) on first use"
echo "  - Accessibility: allow Karabiner-Elements"
echo ""
echo "Press the Globe (fn) key to start recording, release to transcribe."
echo "First use will download the Whisper model (~3 GB) — be patient."
