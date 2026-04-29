# Whisper Free

Push-to-talk voice-to-text for macOS. Press your push-to-talk key, speak, release — your words appear as text in whatever app you're using. Runs entirely on-device. No cloud APIs, no subscriptions, no data leaving your machine.

## Requirements

- Apple Silicon Mac (M1 or later). [MLX](https://github.com/ml-explore/mlx) does not run on Intel.
- macOS 13 (Ventura) or later.

Nothing else. The Python interpreter, ML libraries, and Whisper model are bundled inside the app.

## Install

1. Download `WhisperFree.dmg` from the Releases page.
2. Open the DMG and drag `WhisperFree.app` into `/Applications`.
3. First launch: the app is ad-hoc signed (no Apple Developer ID), so macOS Gatekeeper will block it. Either right-click `WhisperFree.app` in Finder, choose **Open**, then click **Open** in the confirmation dialog, or run:

   ```
   xattr -dr com.apple.quarantine /Applications/WhisperFree.app
   ```

   Then double-click to launch normally.

A microphone icon appears in the menu bar. There is no Dock icon.

## Permissions

On first launch, a permissions window asks for two grants:

- **Microphone** — to record audio.
- **Accessibility** — used both to detect your push-to-talk key (via NSEvent global monitor) and to paste transcribed text into the active app.

The Permissions window has a Grant button next to each. If clicking Grant produces no system prompt (macOS only prompts once per app), use **Open Settings** and toggle Whisper Free on manually. You can reopen the window any time from the menu bar (mic icon → **Permissions…**).

## Usage

The default push-to-talk key is **Caps Lock**. Press it once to start recording, press it again to stop. The Caps Lock LED doubles as a recording indicator.

To change the key, click the menu bar mic icon → **Push-to-talk Key** and pick from the list:

- Caps Lock (toggle: press once to start, press again to stop)
- Right Option, Right Command, Right Shift, Right Control (hold to record, release to stop)
- F13–F20 (hold to record, release to stop)

Globe (fn) is intentionally not in the list. macOS filters it out of every userspace event API; the only way to catch it is a kernel-level driver such as Karabiner-Elements.

If Spotify or Apple Music is playing, it pauses while you record and resumes when you release.

The menu bar mic icon switches to a slashed mic when permissions are missing.

## How it works

| Component | Role |
|---|---|
| `WhisperFree.app` (Swift) | Menu-bar controller. Owns the status item, watches the push-to-talk key via NSEvent, signals the daemon over a Unix socket, supervises the daemon process, and handles Launch at Login via `SMAppService`. |
| `stt.py` (Python daemon) | Records audio, runs transcription, pastes text. Listens on `/tmp/whisper_free.sock` for start/stop signals from the menu-bar app. |
| Overlay widget | Shown during recording. Displays live audio level and transcription status. |

### Under the hood

- [Whisper Large v3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo), OpenAI's speech recognition model ported to Apple Silicon by the MLX community.
- [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) runs the model on the Metal GPU via MLX.
- [sounddevice](https://python-sounddevice.readthedocs.io/) captures audio through PortAudio.
- The bundled Python interpreter comes from [python-build-standalone](https://github.com/astral-sh/python-build-standalone), which produces a relocatable CPython tree suitable for embedding in a `.app`.
- Transcription is greedy (`temperature=0`) and each recording is independent (no context carried between transcriptions).

## Configuration

The push-to-talk key is set from the menu bar. Two environment variables also control behavior:

| Variable | Default | Description |
|---|---|---|
| `WHISPER_MODEL` | `mlx-community/whisper-large-v3-turbo` | Hugging Face model id to load. |
| `WHISPER_OVERLAY` | `1` | Set to `0` to disable the overlay widget. |

To override these, edit `WhisperFree.app/Contents/Info.plist` (adding an `LSEnvironment` dictionary) or launch the app from a shell with the variables exported.

## Build from source

```
cd app
./setup-signing-cert.sh   # one-time: install a local codesigning identity
./build.sh
```

Prerequisites: Apple Silicon Mac, Xcode Command Line Tools (`xcode-select --install`).

The first build downloads a standalone Python runtime (~20 MB) and then installs the Python deps (mlx-whisper, sounddevice, pyobjc, numpy, etc., ~500 MB resolved). It takes a few minutes. Subsequent builds reuse the cached runtime and deps.

`setup-signing-cert.sh` creates a self-signed codesigning identity in your login keychain. macOS will prompt once for your password to confirm codesign can use the key; click "Always Allow". Without this step the build still works, but under ad-hoc signing each rebuild produces a new CDHash, which invalidates every macOS privacy grant (Microphone, Accessibility) — you'd have to re-approve the app each time. With the self-signed identity, the bundle's Designated Requirement is stable across rebuilds and grants stick.

Output (outside the repo so macOS file-provider sync doesn't interfere with signing):

- `~/Library/Developer/WhisperFree/WhisperFree.app` — the bundled app.
- `~/Library/Developer/WhisperFree/WhisperFree.dmg` — a drag-to-Applications disk image.

## Known limitations

- Apple Silicon only. MLX has no Intel path.
- Unsigned. First launch needs the Gatekeeper bypass described in Install. If the project is ever distributed more widely it will be signed and notarized.
- The overlay is a precompiled ARM64 binary; the source is not included in this repo. The daemon runs fine without it (`WHISPER_OVERLAY=0`), you just lose the visual indicator.
- Media pause/resume covers Spotify and Apple Music only. Browsers, VLC, and other players are not detected.
- Globe (fn) is unavailable as a push-to-talk key. macOS filters fn out of `CGEventTap`, `NSEvent.addGlobalMonitorForEvents`, and other userspace observation APIs. Karabiner-Elements gets around this with a kernel-level virtual HID driver, which is more dependency than this project wants. Pick another key from the list.

## Uninstall

Drag `/Applications/WhisperFree.app` to the Trash.

Optional cleanup:

```
rm -rf ~/Library/Logs/whisper-free
rm -rf ~/Library/Application\ Support/WhisperFree
```

The second path is only present if the app has written user state there.
