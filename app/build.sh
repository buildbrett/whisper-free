#!/usr/bin/env bash
#
# build.sh — Build a distributable macOS .app bundle and .dmg for Whisper Free.
#
# Produces:
#   ~/Library/Developer/WhisperFree/WhisperFree.app
#   ~/Library/Developer/WhisperFree/WhisperFree.dmg
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
APP_NAME="WhisperFree"
DISPLAY_NAME="Whisper Free"
BUNDLE_ID="com.local.whisperfree"

PYTHON_STANDALONE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260414/cpython-3.13.13%2B20260414-aarch64-apple-darwin-install_only.tar.gz"

# Stage + final output live outside the repo: macOS's file provider (iCloud
# Drive / Documents sync) attaches xattrs like com.apple.FinderInfo to anything
# inside ~/Documents/, and codesign refuses to sign a bundle with those
# attributes attached. ~/Library/Caches/ and ~/Library/Developer/ aren't
# file-provider-managed, so staging + signing there is robust.
BUILD_DIR="$HOME/Library/Caches/WhisperFreeBuild"
STAGE_DIR="$BUILD_DIR/stage"
DIST_DIR="$HOME/Library/Developer/WhisperFree"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
PYTHON_STANDALONE_TARBALL="$BUILD_DIR/python-standalone.tar.gz"

SWIFT_PKG_DIR="$REPO_ROOT/app/WhisperFreeApp"
SWIFT_BINARY="$SWIFT_PKG_DIR/.build/release/WhisperFree"

INFO_PLIST_SRC="$REPO_ROOT/app/Info.plist"
ICON_SRC="$REPO_ROOT/app/Assets/AppIcon.icns"
STT_SRC="$REPO_ROOT/stt.py"
OVERLAY_SRC_DIR="$REPO_ROOT/overlay"
REQUIREMENTS_SRC="$REPO_ROOT/requirements.txt"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log() {
    printf '==> %s\n' "$*"
}

err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
log "Preflight checks"

if [[ "$(uname -s)" != "Darwin" ]]; then
    err "This build script only runs on macOS (got $(uname -s))."
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    err "This build script requires an arm64 (Apple Silicon) host (got $(uname -m))."
fi

for cmd in swift codesign hdiutil curl tar python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "Required command '$cmd' not found in PATH."
    fi
done

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------
log "Cleaning stage and dist directories"
rm -rf "$STAGE_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR" "$DIST_DIR"

# -----------------------------------------------------------------------------
# Compile the Swift app
# -----------------------------------------------------------------------------
log "Building Swift app (release, arm64)"
if [[ ! -d "$SWIFT_PKG_DIR" ]]; then
    err "Swift package directory missing: $SWIFT_PKG_DIR"
fi
(
    cd "$SWIFT_PKG_DIR"
    swift build -c release --arch arm64
)
if [[ ! -f "$SWIFT_BINARY" ]]; then
    err "Swift build did not produce binary at $SWIFT_BINARY"
fi

# -----------------------------------------------------------------------------
# Assemble bundle skeleton
# -----------------------------------------------------------------------------
log "Assembling bundle skeleton"
STAGE_APP="$STAGE_DIR/$APP_NAME.app"
CONTENTS_DIR="$STAGE_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RES_DIR"

if [[ ! -f "$INFO_PLIST_SRC" ]]; then
    err "Info.plist missing at $INFO_PLIST_SRC"
fi
cp "$INFO_PLIST_SRC" "$CONTENTS_DIR/Info.plist"

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

cp "$SWIFT_BINARY" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RES_DIR/AppIcon.icns"
else
    log "warning: no icon found at $ICON_SRC, continuing without one"
fi

# -----------------------------------------------------------------------------
# Download + extract python-build-standalone
# -----------------------------------------------------------------------------
if [[ ! -f "$PYTHON_STANDALONE_TARBALL" ]]; then
    log "Downloading python-build-standalone"
    curl -fLo "$PYTHON_STANDALONE_TARBALL" "$PYTHON_STANDALONE_URL"
else
    log "Using cached python-build-standalone tarball"
fi

log "Verifying tarball integrity"
if ! tar tzf "$PYTHON_STANDALONE_TARBALL" >/dev/null 2>&1; then
    rm -f "$PYTHON_STANDALONE_TARBALL"
    err "Cached python-build-standalone tarball was corrupt (removed). Re-run build to re-download."
fi

log "Extracting python-build-standalone"
PY_EXTRACT_DIR="$(mktemp -d "$BUILD_DIR/py-extract.XXXXXX")"
trap 'rm -rf "$PY_EXTRACT_DIR"' EXIT
tar -xzf "$PYTHON_STANDALONE_TARBALL" -C "$PY_EXTRACT_DIR"
if [[ ! -d "$PY_EXTRACT_DIR/python" ]]; then
    err "Expected top-level 'python/' inside tarball, not found."
fi
mv "$PY_EXTRACT_DIR/python" "$RES_DIR/python"

BUNDLED_PYTHON="$RES_DIR/python/bin/python3"
if [[ ! -x "$BUNDLED_PYTHON" ]]; then
    err "Bundled python3 missing or not executable at $BUNDLED_PYTHON"
fi

# -----------------------------------------------------------------------------
# Install Python dependencies
# -----------------------------------------------------------------------------
if [[ ! -f "$REQUIREMENTS_SRC" ]]; then
    err "requirements.txt missing at $REQUIREMENTS_SRC"
fi

log "Upgrading pip inside bundled interpreter"
"$BUNDLED_PYTHON" -m pip install --upgrade pip

log "Installing Python requirements into bundle (this can take several minutes)"
"$BUNDLED_PYTHON" -m pip install -r "$REQUIREMENTS_SRC"

# -----------------------------------------------------------------------------
# Copy daemon and overlay
# -----------------------------------------------------------------------------
log "Copying daemon and overlay"
if [[ ! -f "$STT_SRC" ]]; then
    err "stt.py missing at $STT_SRC"
fi
cp "$STT_SRC" "$RES_DIR/stt.py"

if [[ -d "$OVERLAY_SRC_DIR" ]]; then
    cp -R "$OVERLAY_SRC_DIR" "$RES_DIR/overlay"
fi

# -----------------------------------------------------------------------------
# Strip __pycache__ and .pyc
# -----------------------------------------------------------------------------
log "Stripping __pycache__ directories"
find "$RES_DIR/python" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$RES_DIR/python" -type f -name '*.pyc' -delete 2>/dev/null || true

# -----------------------------------------------------------------------------
# Ad-hoc codesign
# -----------------------------------------------------------------------------
log "Ad-hoc signing bundle contents"

# Sign every .so and .dylib bottom-up first.
while IFS= read -r -d '' f; do
    codesign --sign - --force --timestamp=none "$f" >/dev/null 2>&1 || true
done < <(find "$RES_DIR" \( -name '*.so' -o -name '*.dylib' \) -type f -print0)

# Sign any other Mach-O executables under Resources.
while IFS= read -r -d '' f; do
    if file "$f" 2>/dev/null | grep -q 'Mach-O'; then
        codesign --sign - --force --timestamp=none "$f" >/dev/null 2>&1 || true
    fi
done < <(find "$RES_DIR" -type f -perm -u+x -print0)

# Sign the main executable.
codesign --sign - --force --timestamp=none "$MACOS_DIR/$APP_NAME" >/dev/null 2>&1 || true

log "Signing bundle (final --deep pass)"
codesign --sign - --force --deep "$STAGE_APP" 2>&1 | grep -v '^$' || true

log "Verifying signature (warnings about nested content are expected)"
codesign --verify --verbose=2 "$STAGE_APP" 2>&1 || true

# -----------------------------------------------------------------------------
# Move to dist
# -----------------------------------------------------------------------------
log "Moving bundle to dist/"
mv "$STAGE_APP" "$APP_BUNDLE"

# -----------------------------------------------------------------------------
# Create .dmg
# -----------------------------------------------------------------------------
log "Creating .dmg"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"

rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGE"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
BUNDLE_SIZE="$(du -sh "$APP_BUNDLE" | awk '{print $1}')"
DMG_SIZE="$(du -sh "$DMG_PATH" | awk '{print $1}')"

log "Done"
printf '    bundle: %s  (%s)\n' "$APP_BUNDLE" "$BUNDLE_SIZE"
printf '    dmg:    %s  (%s)\n' "$DMG_PATH" "$DMG_SIZE"

exit 0
