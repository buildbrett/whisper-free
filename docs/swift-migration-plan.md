# Whisper Free Swift migration plan

A migration from the current Python daemon plus Swift host to a single native Swift app, motivated by App Store eligibility (Guideline 2.5.2, sandbox compatibility) and a roughly 800 MB bundle reduction.

The current shape: `WhisperFree.app` is a Swift menu-bar app that spawns a bundled `python-build-standalone` interpreter running `stt.py`. The Swift side already owns the fn-key listener, media pause, overlay UI, permissions, and login-item handling. Python owns audio capture (`sounddevice`), Whisper inference (`mlx-whisper`), and paste (`osascript` Cmd-V). Communication is two Unix domain sockets: `/tmp/whisper_free.sock` (Swift to Python: `start`, `stop`) and `/tmp/whisper_overlay.sock` (Python to Swift: `recording_start`, `level:0.123`, `transcribing_start`, etc.). After this migration, both sockets and the entire interpreter go away.

## 1. Whisper inference library

**Recommended: WhisperKit (argmaxinc/WhisperKit), pin to 0.10.x, run `openai_whisper-large-v3-v20240930_turbo` from the WhisperKit HF repo.**

What's in scope:

- **WhisperKit** (Argmax, MIT licence). CoreML-based, ANE+GPU+CPU dispatch with their `MLComputeUnits.cpuAndGPU` or `.cpuAndNeuralEngine` policy. Supports v3-turbo natively. Argmax publishes prebuilt model variants on Hugging Face under `argmaxinc/whisperkit-coreml`. The 949 M-parameter `large-v3-turbo` quantised builds run roughly real-time-factor 50-90x on M-series for short clips per Argmax's published benchmarks; on M1 their reported RTF for distil-large-v3 is in the 30-60x range, and turbo is faster than distil-large because of the 4-decoder-layer architecture. SwiftPM-installable, actively maintained (releases roughly every 2-4 weeks through 2024-2025), used in production by Argmax's own apps. Min target macOS 13.
- **mlx-swift-examples** (`ml-explore/mlx-swift-examples`, MIT, Apple). MLX itself has Swift bindings, and the examples repo includes a `WhisperEx` port. The port is functional but is not a first-class shipping product: model loading expects `mlx-community` HF layout, the API surface changes with MLX releases, and there's no equivalent of WhisperKit's prebuilt CoreML packages, model selection UI, or VAD chunking. Performance roughly tracks Python `mlx-whisper` since it's the same kernels; in practice WhisperKit on ANE will tie or beat it on M1/M2 because the encoder runs on the Neural Engine instead of GPU and frees the GPU for everything else the user is doing.
- **whisper.cpp via SwiftPM** (`ggerganov/whisper.cpp`, MIT). Mature, GGML-quantised, has Metal kernels. Slower than WhisperKit and mlx-whisper on Apple Silicon for large-v3-turbo; not worth the regression.
- **Apple `SFSpeechRecognizer`** is not Whisper. Different model, different quality envelope, sends audio to Apple servers unless you opt into on-device which is locale-restricted. Out.

**Why WhisperKit over mlx-swift:** ANE offload (encoder runs on Neural Engine, big win at idle and battery), prebuilt quantised packages avoid a custom conversion pipeline, model packages are signed CoreML `.mlmodelc` directories Apple is fine with, the project is currently the path Apple themselves point at for "speech on Apple Silicon", and the API is stable enough to pin. The mlx-swift WhisperEx route is maintained but is research-grade; we'd be the integration QA. If WhisperKit ever falls off, swapping to mlx-swift is a multi-day job because the audio pipeline and threading shape are similar.

Cite: `https://github.com/argmaxinc/WhisperKit`, `https://huggingface.co/argmaxinc/whisperkit-coreml`, Argmax benchmarks at `https://www.takeargmax.com/blog/whisperkit-benchmarks`.

## 2. Model packaging strategy

**Bundle the model inside `Resources/Models/` in the `.app`.**

Sizes for the Argmax CoreML turbo variant:

- `openai_whisper-large-v3-v20240930_turbo` (FP16): ~1.6 GB on disk
- `openai_whisper-large-v3-v20240930_turbo_632MB` (4-bit weights, 8-bit activations): ~630 MB
- `openai_whisper-large-v3-v20240930_turbo_547MB` (mixed quant): ~550 MB

Recommend the `_632MB` 4-bit build. Quality regression vs FP16 turbo is minor on dictation (Argmax reports WER deltas under 1% on common evals); shaving a gigabyte off the bundle matters more than that. End bundle size is roughly 700-750 MB, down from the current 897 MB once Python+numpy+scipy+numba are gone.

First-run download is rejected: it is the same Guideline 2.5.2 concern that's driving this migration. The model files include compiled CoreML artifacts (`.mlmodelc/coremldata.bin`, `weights/weight.bin`) which reviewers can construe as "executable code" if downloaded post-install. Bundle once, ship once.

For direct distribution we still bundle because the same source tree produces both targets and we don't want forked behaviour.

## 3. Audio capture

Replace `sounddevice.InputStream` with `AVAudioEngine`. Concrete shape:

```
AVAudioSession-equivalent setup (macOS doesn't use AVAudioSession, just AVAudioEngine)
  → engine.inputNode
  → installTap(onBus: 0, bufferSize: 1024, format: inputFormat)
  → AVAudioConverter to {16 kHz, 1 channel, Float32 PCM}
  → ring buffer of converted samples (Swift Array<Float> in an actor)
  → on stop: hand the buffer to WhisperKit
```

Gotchas:

- **Format conversion.** The input node delivers samples at the device's native rate (44.1, 48, 96 kHz) and channel count. WhisperKit wants 16 kHz mono float32. Use `AVAudioConverter` with `AVAudioConverterPrimeMethod.none` and feed it via `AVAudioConverter.convert(to:error:withInputFrom:)` to handle non-integer ratios cleanly. Don't try to resample by decimation; you will spend a week chasing aliasing artifacts.
- **Buffer size.** 1024 frames at the input device rate is 21-23 ms at 48 kHz; that's the smallest practical tap size on macOS. Anything smaller is silently rounded up. For the level meter going to the orb (currently `level:` socket messages at 25 fps), compute RMS on each tap callback after conversion and throttle the publish to the same 25 fps the Python side did.
- **Device changes mid-recording.** macOS posts `AVAudioEngineConfigurationChange` when the default input changes (headphones plugged in, AirPods connected, USB mic attached). Subscribe to it, stop the engine, rebuild the converter against the new input format, and restart the engine. If a recording is in flight, decide policy: either splice the two segments and warn (probably fine for dictation), or end the recording cleanly with a notification. Recommend splicing.
- **Permission.** `AVCaptureDevice.requestAccess(for: .audio)` triggers the Microphone TCC prompt. The current `NSMicrophoneUsageDescription` string in `Info.plist` already covers it.
- **Engine lifetime.** Keep one `AVAudioEngine` for the life of the app. Starting and stopping the engine for each push-to-talk press adds ~80-200 ms of latency on the leading edge. Install the tap on demand; leave the engine running.
- **Sample rate of the converter.** Some USB interfaces report odd rates (44.1 vs 48). Always read `inputNode.inputFormat(forBus: 0)` immediately before installing the tap, not at engine init.

## 4. Paste mechanism in a sandboxed app

Goal: replicate the current `osascript`-driven Cmd-V into the active text field, but compatible with App Sandbox + Hardened Runtime.

Map of options:

1. **CGEvent key synthesis.** `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `CGKeyCode(0x09)` (V) plus the command modifier flag, then `event.post(tap: .cgSessionEventTap)`. This is what every clipboard manager and text-expander on macOS uses (TextExpander, Raycast, Alfred). It requires the user to grant the app **Accessibility** in System Settings, which the current app already requires for the global key monitor. Sandbox compatibility: works inside the sandbox without any temporary-exception entitlement, because `CGEventPost` is gated by Accessibility (TCC), not by the sandbox profile.
2. **NSPasteboard write only, no synthesised paste.** Equivalent to pressing copy, then asking the user to press Cmd-V. Drops a core UX feature. Reject.
3. **AXUIElement insertion** via `AXUIElementSetAttributeValue` with `kAXSelectedTextAttribute`. This inserts text directly into the focused field via Accessibility APIs. Works for native Cocoa text fields, mostly works for Electron, fails for Terminal, fails for some web inputs in browsers, fails for VS Code. Inconsistent enough to be a UX regression.
4. **Apple Events (`osascript`).** Requires `com.apple.security.temporary-exception.apple-events` listing every target bundle, which Apple reviews for plausibility. This is what the BACKLOG calls out; not worth it.

**Take option 1.** Keep the current "copy, paste, restore prior clipboard" flow but replace the `osascript -e 'tell application "System Events"...'` call with a `CGEvent` Cmd-V synth. The clipboard restore logic from `paste_text()` in `stt.py` (lines 207-273) ports almost directly to Swift `NSPasteboard.general` and `NSPasteboardItem` — same API surface.

Entitlements file (new), for both direct and App Store builds:

```
com.apple.security.app-sandbox          = true   (App Store) / omit (direct)
com.apple.security.device.audio-input   = true
com.apple.security.network.client       = false  (no runtime network)
com.apple.security.files.user-selected.read-only = true   (only if we add file-import later)
com.apple.security.automation.apple-events = false
```

Plus the existing TCC requirements declared via Info.plist usage strings: `NSMicrophoneUsageDescription` (already there) and accessibility (TCC, no Info.plist key required, but we already prompt). No new TCC prompts beyond what the user grants today.

## 5. Migration sequence

**Pick big-bang on a branch, not incremental.**

Reasoning: the incremental path would mean keeping Python in the bundle while moving inference into Swift, which requires the Swift side to call into the running Python daemon for transcription via the existing socket — and that's a backwards integration we'd have to write and then immediately delete. The Swift side already owns audio capture (sort of, via Python), key listening, media, overlay. Inference and paste are the two remaining Python responsibilities. Once those move to Swift, the daemon has nothing left to do. The work to keep them coexisting is larger than the work to swap them out.

Phases on a branch named `swift-native`:

**Phase 0 — scaffold and dependency wiring (1-2 days).**
Add WhisperKit as a SwiftPM dependency in `Package.swift`. Bump `swift-tools-version` only if WhisperKit requires it (currently 5.9 should be enough). Add an entitlements file and wire `build.sh` to apply it during codesign.

**Phase 1 — model bundling (1 day).**
Pull the `_632MB` turbo CoreML package from `argmaxinc/whisperkit-coreml`. Add a `download-model.sh` step in `build.sh` that fetches and verifies it, then copies it to `Resources/Models/whisper-large-v3-turbo`. Cache the download in `~/Library/Caches/WhisperFreeBuild/` like the Python tarball is cached today.

**Phase 2 — inference engine (3-5 days).**
New file `Sources/WhisperFree/InferenceEngine.swift`. Wraps `WhisperKit` with `init(modelFolder:)`, async `transcribe(audio: [Float]) -> String`, and a one-shot warm-up call on app launch. Use a `@MainActor`-isolated facade for state, `nonisolated` for the inference call. Keep one WhisperKit instance for the life of the app.

**Phase 3 — audio capture (3-4 days).**
New file `AudioRecorder.swift`. Replaces both `sounddevice` and `Recorder` in `stt.py`. Owns the `AVAudioEngine`, exposes `start()`, `stop() -> [Float]`, and a `level: AsyncStream<Float>` the overlay subscribes to. Internally an actor.

**Phase 4 — paste (1-2 days).**
New file `Pasteboard.swift`. Ports `paste_text()` from `stt.py`. CGEvent Cmd-V plus the clipboard snapshot/restore.

**Phase 5 — wire it together and delete sockets (2-3 days).**
`AppDelegate` no longer constructs `DaemonController`. The fn key listener calls `AudioRecorder.start()` directly on press, `AudioRecorder.stop()` on release, then hands the buffer to `InferenceEngine`, then to `Pasteboard`. The overlay subscribes to `AudioRecorder.level` and `InferenceEngine.phase` directly via `@Published`/Combine, no Unix sockets.

**Phase 6 — entitlements, signing, build (2-3 days).**
Update `build.sh` to drop all Python steps, drop the overlay copy step (already a no-op), and add `--entitlements` to codesign. Strip `setup-signing-cert.sh` references when we move to Developer ID, but keep the local self-signed flow for development.

**Phase 7 — parity testing and tuning (3-5 days).**
See section 8.

Total: 16-25 days of focused work for a single developer.

## 6. File-by-file impact

Repo root:

- `stt.py` — deleted.
- `requirements.txt` — deleted.
- `BACKLOG.md` — modified: strike the App Store viability section's "drop Python" and "bundle the model" items, leave the rest, add a note pointing at the migration commit.
- `README.md` — modified: rewrite the build prerequisites and architecture section.
- `overlay/` — deleted (already dead code per BACKLOG).

`app/`:

- `Info.plist` — modified: remove the MLX-specific phrasing in the mic usage string ("using Whisper on Apple's MLX framework" → "using on-device speech recognition"). Add `LSApplicationCategoryType = public.app-category.productivity`. Add `ITSAppUsesNonExemptEncryption = false`.
- `WhisperFreeApp.entitlements` — new file. Contents in section 4.
- `Package.swift` — modified: add WhisperKit as a SwiftPM dependency, bump tools version only if needed.
- `build.sh` — modified, large diff: delete sections 7 ("Download + extract python-build-standalone"), 8 ("Install Python dependencies"), 9 ("Copy daemon and overlay"), and 10 ("Strip __pycache__"). Add a model download step. Add `--entitlements` to the bundle codesign. Drop the `STT_SRC`, `OVERLAY_SRC_DIR`, `REQUIREMENTS_SRC`, `PYTHON_STANDALONE_URL`, `PYTHON_STANDALONE_TARBALL`, and related variables.
- `setup-signing-cert.sh` — keep for development, but write a follow-up to migrate to Developer ID when we go for distribution.
- `dmg-background.swift`, `Assets/` — unchanged.

`app/WhisperFreeApp/Sources/WhisperFree/`:

- `AppDelegate.swift` — modified: remove `DaemonController` field and its lifecycle calls; add `audioRecorder`, `inferenceEngine`, `pasteboard` as fields; delete the `restartDaemon` menu item and handler. The `Status: Running` line either goes away or becomes `Status: Ready` driven by `InferenceEngine` warm-up state.
- `DaemonController.swift` — deleted.
- `OverlayController.swift` — modified, smaller: remove the Unix-socket binding, take an `AudioRecorder` and `InferenceEngine` reference at init, subscribe to their published state. The Orb visualizer stays.
- `FnKeyListener.swift` — modified: replace `send("start")` / `send("stop")` over the socket with direct calls into `AudioRecorder` plus the inference and paste pipeline. Drop the `clientSocket` field and all sockaddr_un plumbing.
- `MediaController.swift` — unchanged.
- `PermissionsManager.swift`, `PermissionsWindow.swift` — possibly modified, depending on whether we want to add a "Speech models loaded" check; not strictly required.
- `Log.swift`, `LoginItem.swift`, `PushToTalkKey.swift`, `main.swift`, `Orb/` — unchanged.
- `AudioRecorder.swift` — new, ~150 LOC.
- `InferenceEngine.swift` — new, ~80 LOC.
- `Pasteboard.swift` — new, ~70 LOC.

The bundled Python interpreter and entire site-packages tree (numpy, mlx, mlx-whisper, sounddevice, scipy, numba, llvmlite, etc., everything under `Resources/python/`) is gone.

## 7. Risk register

**WhisperKit perf below mlx-whisper turbo on M1.** Severity: high (a perf regression is a UX regression on the user's primary machine, an M1). Likelihood: low to medium. WhisperKit on ANE typically beats GPU-only mlx-whisper on M1 for the encoder, but the decoder runs on GPU regardless and the cross-runtime comparison varies by clip length. Mitigation: benchmark on M1 before deleting `stt.py`. If we see >20% regression on the parity clip set, fall back to `_547MB` mixed-quant build, then to FP16 if needed; final fallback is mlx-swift-examples WhisperEx, with a 5-day schedule add.

**Argmax licensing or maintenance shift.** Severity: medium. Likelihood: low. WhisperKit is MIT and Argmax has an obvious commercial interest in keeping it healthy (their hosted product depends on it). The CoreML model packages on the HF repo are MIT under OpenAI's original Whisper licence (MIT). If Argmax pivots, the SwiftPM package keeps working at the pinned version, and we'd have time to fork or migrate.

**CGEvent paste blocked or flagged in App Store review.** Severity: high (it's the entire UX). Likelihood: medium. App Store reviewers have rejected key-synthesis apps before, especially when the description doesn't make obvious why it needs Accessibility. Mitigation: write the reviewer notes to explain push-to-talk dictation requires inserting text into the active app, point at TextExpander/Raycast as precedent, and stage a fallback of "copy to clipboard + show a toast" if Apple denies. The review-rejection cycle is real, plan for two rounds.

**Concurrency shape.** The Python daemon was effectively single-threaded with a blocking socket loop. Swift will have at least three concurrency domains: the audio thread (AVAudioEngine callbacks, real-time priority, must not allocate), inference (background, CPU+ANE), and the main actor (UI, key events). Severity: medium. Mitigation: model `AudioRecorder` as an actor that hands ring-buffered samples to inference via `AsyncStream<[Float]>`; `InferenceEngine` is a class not an actor (WhisperKit calls are blocking, run them on a dedicated `DispatchQueue` or `Task.detached(priority: .userInitiated)`); main-actor for UI. Don't let SwiftUI binding chains pull audio-thread state.

**macOS version drift mid-migration.** WhisperKit declares macOS 13 minimum but uses CoreML APIs; some quantised weight loaders need macOS 14. Severity: low. Likelihood: low. We're already 14+. Test on 14, 15, 26.

**Sandbox and Accessibility interaction.** App Sandbox plus the Accessibility TCC grant historically did not coexist for some entitlement combinations on older OSes. Severity: medium. Likelihood: low (Apple supports this for clipboard/text apps). Mitigation: file the Accessibility prompt in the migration's first sandboxed test build before any other work, confirm CGEvent posts work end-to-end.

**Live audio device change crashes the engine.** Severity: medium. Likelihood: high if untested. Mitigation: write an integration test that toggles default input mid-recording (done by switching default device via `AudioObjectSetPropertyData`); easy to script.

## 8. Test strategy

**Parity fixtures.** Pick 6-10 audio clips that cover the dictation envelope: a short utterance ("set timer for ten minutes"), a long utterance (60s), a clip with technical jargon (proper nouns the user actually says), a clip with hesitation and filler words, a clip with background noise, a clip in a non-English locale if relevant. Save WAVs in `tests/fixtures/`.

**Old-pipeline reference.** Before deleting Python, run `stt.py`'s `transcribe()` over each fixture and save the resulting text plus elapsed-time JSON to `tests/baseline.json`. This is the parity target.

**New-pipeline harness.** A small Swift test executable (`Sources/WhisperFreeTests/main.swift` or an XCTest target) loads each fixture, runs it through `InferenceEngine.transcribe()`, and writes the same JSON shape. A diff script compares text WER and elapsed-time delta. Pass thresholds: text exact-match for 70% of fixtures, WER < 0.05 on the rest, time within 1.5x of baseline.

**Audio capture parity.** Record a 10-second clip of a known signal (1 kHz sine into a quiet room) through both pipelines, save WAVs, diff the spectrograms or just the RMS curve. The Python `sounddevice` path and the Swift `AVAudioEngine` path should produce indistinguishable buffers after the AVAudioConverter step.

**Paste end-to-end.** Manual smoke list: TextEdit, Notes, Safari address bar, Slack, VS Code, Terminal, iTerm, Chrome, Xcode source editor. The current Python paste works on all of these; the new Swift paste must match.

**Latency.** Measure time-from-key-release to time-of-text-appearing. Current pipeline: roughly 200-600 ms for a short utterance on M-series. New pipeline should match or beat. Instrument with `os_signpost` on both branches and compare.

## 9. Effort estimate

| Phase | Days (single developer) |
| --- | --- |
| 0. Scaffold and dependencies | 1-2 |
| 1. Model bundling | 1 |
| 2. Inference engine | 3-5 |
| 3. Audio capture | 3-4 |
| 4. Paste | 1-2 |
| 5. Wire-up and delete sockets | 2-3 |
| 6. Entitlements, signing, build pipeline | 2-3 |
| 7. Parity testing and tuning | 3-5 |
| **Total** | **16-25** |

Double if you want to be honest about distractions. So plan for 4-6 weeks calendar time at 50% focus.

## 10. Decisions to make before starting

A pre-flight checklist. Recommended answer first, alternative second, what flips it third.

- [ ] **Inference library: WhisperKit.** Alternative: mlx-swift-examples WhisperEx. Flip if WhisperKit's M1 perf regresses by >20% in your benchmark, or if Argmax's HF repo licence terms change.
- [ ] **Model variant: large-v3-turbo `_632MB` (4-bit).** Alternative: `_547MB` mixed-quant or full FP16 (~1.6 GB). Flip to FP16 if A/B testing shows quality drop you can't tolerate; flip to `_547MB` if A/B shows it's quality-equal at lower size.
- [ ] **Model packaging: bundled in `.app`.** Alternative: first-run download with progress UI. Flip only if you abandon App Store ambitions and ship direct-only forever.
- [ ] **Migration shape: big-bang on a branch.** Alternative: incremental with sockets-still-up. Flip if you discover during Phase 2 that WhisperKit needs a major rework, in which case keep Python as the inference fallback and migrate audio first.
- [ ] **Paste mechanism: CGEvent Cmd-V.** Alternative: AXUIElement direct insertion. Flip if Apple rejects CGEvent in App Store review (run a test submission first).
- [ ] **Distribution: Developer ID + DMG first, App Store later.** Alternative: App Store first. Flip if you want App Store discoverability more than ship-this-month timing; recommended only after the migration is parity-tested.
- [ ] **Accessibility prompt UX: keep current "Permissions…" window.** Alternative: redesign as part of the migration. Flip only if you're already touching that code; otherwise leave it.
- [ ] **Sandboxed log path: switch to container-relative on App Store builds.** Alternative: keep `~/Library/Logs/whisper-free` everywhere (works direct, breaks sandboxed). Flip is forced by App Store path.
- [ ] **Min macOS: stay at 14.** Alternative: bump to 15. Don't bump unless WhisperKit forces it.
- [ ] **Tests: write parity harness before deleting `stt.py`.** Alternative: skip the harness, eyeball it. Don't.
