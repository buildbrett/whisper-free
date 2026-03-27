# Whisper Free

Push-to-talk voice-to-text for macOS. Hold the Globe key, speak, release — your words appear as text in whatever app you're using. Runs entirely on-device. No cloud APIs, no subscriptions, no data leaving your machine.

## Requirements

**Apple Silicon Mac only.** This project uses [MLX](https://github.com/ml-explore/mlx), Apple's machine learning framework that runs on the Metal GPU in M-series chips. It will not work on Intel Macs.

- macOS 13 (Ventura) or later
- Apple Silicon (M1, M2, M3, M4, or later)
- Python 3.12+
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) (for the Globe key hotkey)
- ~3 GB of disk space for the Whisper model (downloaded on first use)

## Install

```
git clone <repo-url> whisper-free
cd whisper-free
./install.sh
```

The install script will:

1. Create a Python virtual environment and install dependencies
2. Register a background daemon (launchd) that starts automatically at login
3. Configure Karabiner-Elements to use the Globe (fn) key as push-to-talk

On first use, the Whisper model (~3 GB) downloads from Hugging Face automatically. The first transcription will be slow while this happens.

### Permissions

macOS will prompt you to grant these permissions (System Settings > Privacy & Security):

- **Microphone** — so the daemon can record audio
- **Accessibility** — so Karabiner-Elements can capture the Globe key, and so transcribed text can be pasted into apps

## Usage

1. **Hold the Globe (fn) key** — recording starts and a small overlay widget appears
2. **Speak** — the overlay shows your audio level in real-time
3. **Release the key** — recording stops, audio is transcribed, and the text is pasted into the active text field

If music is playing in Spotify or Apple Music, it pauses automatically while recording and resumes when you release the key.

## How it works

| Component | Role |
|---|---|
| **stt.py** | Background daemon — records audio, runs transcription, pastes text |
| **stt-send.sh** | Tiny helper that sends start/stop signals to the daemon over a Unix socket |
| **overlay/voice-to-text-widget** | Native macOS widget that shows recording status and audio levels |
| **Karabiner-Elements** | Captures Globe key press/release and triggers the shell scripts |
| **launchd** | Keeps the daemon running and restarts it if it crashes |

### Under the hood

- **[Whisper Large v3 Turbo](https://huggingface.co/mlx-community/whisper-large-v3-turbo)** — OpenAI's speech recognition model, optimized for Apple Silicon via the MLX community
- **[mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)** — Runs the Whisper model on-device using Apple's Metal GPU through MLX
- **[sounddevice](https://python-sounddevice.readthedocs.io/)** — Captures audio from the microphone via PortAudio
- Transcription is greedy (temperature=0) and each recording is independent (no context carried between transcriptions)

## Configuration

Environment variables (set in the launchd plist or your shell):

| Variable | Default | Description |
|---|---|---|
| `WHISPER_MODEL` | `mlx-community/whisper-large-v3-turbo` | Hugging Face model to use |
| `WHISPER_OVERLAY` | `1` | Set to `0` to disable the overlay widget |

## Uninstall

```
./uninstall.sh
```

This stops the daemon, removes the launchd config, and removes the Karabiner hotkey rule. The project files remain in place — delete the directory to fully remove.

## Known limitations

- **Apple Silicon only** — MLX does not support Intel Macs. There is no CPU-only fallback.
- **Overlay binary is precompiled** — The `overlay/voice-to-text-widget` is a precompiled ARM64 binary. The source is not currently included in this repo, so the overlay cannot be rebuilt from source. The daemon works without it (set `WHISPER_OVERLAY=0`), but you lose the visual recording indicator.
- **Media control** — Automatic pause/resume only works with Spotify and Apple Music. Other media apps (browsers, VLC, etc.) are not detected.
- **Globe key only** — The hotkey is hardcoded to the Globe (fn) key via Karabiner. To use a different key, edit the Karabiner rule in `~/.config/karabiner/karabiner.json`.
