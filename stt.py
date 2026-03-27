#!/usr/bin/env python3
"""
Push-to-talk voice-to-text daemon using mlx-whisper.

Listens on a Unix socket for start/stop signals (sent by Karabiner),
records audio while active, transcribes with Whisper on MLX/Metal,
and pastes the result into the active text field.
Also drives a local visual overlay widget via Unix socket events.
"""

import logging
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave

import numpy as np
import sounddevice as sd
from sounddevice import PortAudioError

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

LOG_PATH = os.path.join(_SCRIPT_DIR, "stt.log")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("whisper-free")

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = np.float32
BLOCK_SIZE = 1024
STREAM_OPEN_RETRIES = 3
STREAM_RETRY_DELAY = 0.5

SOCKET_PATH = "/tmp/whisper_free.sock"
MODEL_NAME = os.environ.get("WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo")

OVERLAY_SOCKET_PATH = os.environ.get("WHISPER_OVERLAY_SOCKET", "/tmp/whisper_overlay.sock")
OVERLAY_BIN = os.environ.get("WHISPER_OVERLAY_BIN", os.path.join(_SCRIPT_DIR, "overlay", "voice-to-text-widget"))
ENABLE_OVERLAY = os.environ.get("WHISPER_OVERLAY", "1") != "0"


class OverlayClient:
    def __init__(self, enabled: bool, socket_path: str):
        self.enabled = enabled
        self.socket_path = socket_path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.last_level_ts = 0.0

    def launch_if_needed(self):
        if not self.enabled:
            return

        # If a socket file exists, verify a listener is actually alive.
        if os.path.exists(self.socket_path):
            try:
                self.sock.sendto(b"ping", self.socket_path)
                return
            except OSError:
                try:
                    os.unlink(self.socket_path)
                except FileNotFoundError:
                    pass

        if not os.path.exists(OVERLAY_BIN):
            log.warning("Overlay binary not found at %s", OVERLAY_BIN)
            return

        try:
            subprocess.Popen(
                [OVERLAY_BIN],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            # Give it a short moment to create its socket.
            for _ in range(50):
                if os.path.exists(self.socket_path):
                    break
                time.sleep(0.02)
            log.info("Overlay launched")
        except Exception:
            log.exception("Failed to launch overlay")

    def send(self, message: str):
        if not self.enabled:
            return
        try:
            self.sock.sendto(message.encode("utf-8"), self.socket_path)
        except OSError:
            # Usually means overlay is not running yet; this is non-fatal.
            pass

    def send_level(self, level: float, fps: float = 25.0):
        now = time.monotonic()
        min_dt = 1.0 / fps
        if now - self.last_level_ts < min_dt:
            return
        self.last_level_ts = now
        self.send(f"level:{max(0.0, min(1.0, level)):.3f}")


class Recorder:
    def __init__(self, overlay: OverlayClient):
        self.frames = []
        self.recording = False
        self.stream = None
        self.overlay = overlay

    def _open_stream(self):
        return sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            blocksize=BLOCK_SIZE,
            callback=self._callback,
        )

    def start(self):
        if self.recording:
            return
        self.frames = []

        for attempt in range(1, STREAM_OPEN_RETRIES + 1):
            try:
                self.stream = self._open_stream()
                self.stream.start()
                break
            except PortAudioError:
                if self.stream:
                    try:
                        self.stream.close()
                    except Exception:
                        pass
                    self.stream = None
                if attempt < STREAM_OPEN_RETRIES:
                    log.warning(
                        "PortAudio error opening stream (attempt %d/%d), "
                        "reinitializing audio subsystem...",
                        attempt, STREAM_OPEN_RETRIES,
                    )
                    sd._terminate()
                    sd._initialize()
                    time.sleep(STREAM_RETRY_DELAY)
                else:
                    log.error(
                        "Failed to open audio stream after %d attempts",
                        STREAM_OPEN_RETRIES,
                    )
                    return

        self.recording = True
        self.overlay.launch_if_needed()
        self.overlay.send("recording_start")
        log.info("Recording started")

    def _callback(self, indata, frames, time_info, status):
        if status:
            log.warning("sounddevice status: %s", status)
        if self.recording:
            chunk = indata.copy()
            self.frames.append(chunk)
            rms = float(np.sqrt(np.mean(np.square(chunk), dtype=np.float64)))
            normalized = min(1.0, rms * 14.0)
            self.overlay.send_level(normalized)

    def stop(self):
        if not self.recording:
            return None
        self.recording = False
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        if not self.frames:
            log.warning("No audio frames captured")
            return None
        audio = np.concatenate(self.frames, axis=0)
        duration = len(audio) / SAMPLE_RATE
        log.info("Recording stopped: %.1fs of audio", duration)
        return audio


def save_wav(audio: np.ndarray, path: str):
    audio_int16 = (audio * 32767).astype(np.int16)
    with wave.open(path, "w") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(audio_int16.tobytes())


def paste_text(text: str):
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events" to keystroke "v" using command down',
        ],
        check=True,
    )
    log.info("Pasted %d chars", len(text))


def _pause_media() -> str:
    """Pause currently playing media. Returns app name if paused, else empty string."""
    script = '''
set pausedApp to ""
try
    tell application "System Events"
        if exists process "Spotify" then
            tell application "Spotify"
                if player state is playing then
                    pause
                    set pausedApp to "Spotify"
                end if
            end tell
        end if
    end tell
end try
if pausedApp is "" then
    try
        tell application "System Events"
            if exists process "Music" then
                tell application "Music"
                    if player state is playing then
                        pause
                        set pausedApp to "Music"
                    end if
                end tell
            end if
        end tell
    end try
end if
return pausedApp
'''
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, check=False, timeout=2,
        )
        app = result.stdout.strip()
        if app:
            log.info("Paused media: %s", app)
        return app
    except subprocess.TimeoutExpired:
        log.warning("Media pause timed out")
        return ""


def _resume_media(app_name: str):
    """Resume playback in the specified app."""
    if not app_name:
        return
    try:
        subprocess.run(
            ["osascript", "-e", f'tell application "{app_name}" to play'],
            check=False, timeout=2,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        log.info("Resumed media: %s", app_name)
    except subprocess.TimeoutExpired:
        log.warning("Media resume timed out")


def _clean_transcription(text: str) -> str:
    """Remove Whisper hallucination artifacts like trailing 'Thank you'."""
    for suffix in ("Thank you.", "Thank you", "thank you.", "thank you"):
        if text.endswith(suffix):
            text = text[:-len(suffix)].strip()
            break
    return text


def load_model():
    import mlx_whisper

    log.info("Loading model: %s", MODEL_NAME)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        warmup_path = f.name
    try:
        save_wav(np.zeros((SAMPLE_RATE // 10, 1), dtype=np.float32), warmup_path)
        mlx_whisper.transcribe(warmup_path, path_or_hf_repo=MODEL_NAME)
    finally:
        try:
            os.unlink(warmup_path)
        except FileNotFoundError:
            pass
    log.info("Model ready")
    return mlx_whisper


def transcribe(mlx_whisper, audio: np.ndarray) -> str:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_path = f.name
    try:
        save_wav(audio, tmp_path)
        t0 = time.time()
        result = mlx_whisper.transcribe(
            tmp_path,
            path_or_hf_repo=MODEL_NAME,
            condition_on_previous_text=False,
            temperature=0.0,
        )
        elapsed = time.time() - t0
        text = (result.get("text") or "").strip()
        log.info("Transcribed in %.2fs: %s", elapsed, text[:80])
        return text
    finally:
        os.unlink(tmp_path)


def run_server(mlx_whisper):
    overlay = OverlayClient(enabled=ENABLE_OVERLAY, socket_path=OVERLAY_SOCKET_PATH)
    recorder = Recorder(overlay=overlay)
    paused_app = ""

    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o777)
    log.info("Listening on %s", SOCKET_PATH)

    while True:
        try:
            data = server.recv(64)
            cmd = data.decode("utf-8").strip()

            if cmd == "start":
                paused_app = ""
                def _do_pause():
                    nonlocal paused_app
                    paused_app = _pause_media()
                threading.Thread(target=_do_pause, daemon=True).start()
                recorder.start()
            elif cmd == "stop":
                audio = recorder.stop()
                if audio is not None and len(audio) > SAMPLE_RATE * 0.3:
                    overlay.send("transcribing_start")
                    text = transcribe(mlx_whisper, audio)
                    text = _clean_transcription(text)
                    if text:
                        paste_text(text)
                    overlay.send("transcribing_done")
                else:
                    overlay.send("recording_stop")
                    log.info("Recording too short, skipping")
                _resume_media(paused_app)
                paused_app = ""
            else:
                log.warning("Unknown command: %s", cmd)
        except Exception:
            overlay.send("recording_stop")
            _resume_media(paused_app)
            paused_app = ""
            log.exception("Error processing command")


def cleanup(*args):
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    if ENABLE_OVERLAY:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            s.sendto(b"recording_stop", OVERLAY_SOCKET_PATH)
            s.close()
        except OSError:
            pass
    log.info("Cleaned up, exiting")
    sys.exit(0)


def main():
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    mlx_whisper = load_model()
    run_server(mlx_whisper)


if __name__ == "__main__":
    main()
