# Whisper Free — pre-launch backlog

Things to address before this is something we'd hand to a consumer. Grouped by why they matter, ordered roughly by how much they'd block a public release.

## App Store viability (read this first)

Sandboxing is the elephant in the room. App Store apps must run sandboxed, and several things this app does are flatly incompatible with the standard sandbox profile:

- Spawning a Python subprocess and executing arbitrary downloaded model files (Whisper weights from HuggingFace) is hard to justify under App Store Review Guideline 2.5.2 ("apps may not download or install executable code").
- Synthesizing keystrokes via osascript / `cmd-V` to paste into other apps requires Accessibility, which sandboxed apps cannot request the same way.
- Synthesizing system media keys (`NX_KEYTYPE_PLAY`) and watching global keyboard events both require entitlements that are not granted to sandboxed apps.

Realistic options:

1. **Direct distribution (recommended for v1)** — Apple Developer ID, notarized, stapled ticket. No sandbox, no review. Set up a signed `.dmg` download, optionally Sparkle for updates. Skip the App Store entirely.
2. **App Store path** — would require either (a) shipping a fully native Swift/MLX-Swift implementation with no Python, no model downloads at runtime (model bundled), and a redesigned paste mechanism that works under sandbox, or (b) two products: a sandboxed App Store version with reduced functionality, and a non-sandboxed direct version.

Direct distribution is several weeks of work. App Store path is several months. Pick one before writing more features.

## Code signing and packaging

- [ ] Apple Developer ID Application certificate + Developer ID Installer certificate.
- [ ] Notarization via `notarytool`, stapled ticket on the `.dmg` and the inner `.app`.
- [ ] Replace `setup-signing-cert.sh` and the local self-signed identity with the Developer ID flow in `build.sh`.
- [ ] Write a CI workflow (GitHub Actions on a macOS runner) that builds, signs, notarizes, and uploads the DMG on tag.
- [ ] Sparkle (or equivalent) for in-app auto-update. Self-hosted appcast feed.

## Menu and UX hygiene

The current menu reads like a developer's debug surface. Decide what a consumer actually needs.

- [ ] **Restart Daemon** — useful when something hangs, but rare. Move behind an Option-click reveal, or remove and rely on app relaunch.
- [ ] **Open Logs Folder** — same. Most users will never need it. Keep it for support, but hide unless Option is held.
- [ ] **Status: Running** — does this need to be visible at all? The mic icon already conveys daemon health (it goes `mic.slash` when something is wrong). Probably can drop the line.
- [ ] **Permissions…** — keep, but only show when something is missing. Hide once everything is granted.
- [ ] Add a real **Preferences** window (currently the only setting, push-to-talk key, lives as a submenu). Will need it once we add model selection, vocabulary, language, etc.
- [ ] Visible app icon when transcription is in progress (right now the menu bar icon doesn't change between "ready" and "transcribing").
- [ ] Audible confirmation tone option (Wispr Flow does this — short tick on start/stop).

## Push-to-talk keys

- [ ] Add left-side modifiers: Left Option, Left Command, Left Shift, Left Control. Currently right-side only, which is awkward for left-handed users and for keyboards where the right side is hard to reach (e.g. a 60% with no right-modifier row).
- [ ] Custom hotkey UI: a "press a key" recording field instead of a fixed enum. Lets users pick anything.
- [ ] Optional two-key chord (e.g. `⌃⌥` together) for users who don't want to give up a single modifier.
- [ ] Reconsider Caps Lock default. Toggle semantics confuse first-time users who expect hold-to-record.

## Models and inference

Currently using `mlx-community/whisper-large-v3-turbo`. It's the best balance of size and speed for our purposes; there's no option to go bigger and faster.

- [ ] First-run model download UI. Right now the model downloads on first transcription with no progress indication; a 3 GB silent download is alarming.
- [ ] Custom vocabulary / `initial_prompt` setting. Especially valuable for users with technical jargon, proper nouns, or non-English names that Whisper mangles.
- [ ] Language selection. Currently auto-detect; some users want to lock it.
- [ ] Voice Activity Detection (VAD) to auto-stop after silence, in addition to manual release.

### Streaming transcription — deferred

Considered and intentionally not pursued for now. The idea was to run Whisper on a sliding window every ~500 ms, show committed words as they stabilize via a LocalAgreement-2 algorithm, and keep the actual paste-into-active-app a single event on release (preview shown only in our overlay).

Why deferred: at Turbo's current inference speed on M-series, the post-release wait is already short enough that the perceived-latency gap doesn't justify the engineering. The implementation would add a streaming worker, a LocalAgreement commit state machine, a new overlay UI for committed/tentative text, two new socket message types, plus battery-impact tuning across chip generations. Real cost vs incremental UX gain.

Revisit if: (a) we want to support a "live captioning" feature in addition to dictation, (b) users on slower hardware report objectionable post-release latency on long utterances, or (c) we go fully native Swift/MLX-Swift (a separate large item) and want a flagship feature to differentiate.

## Quality and reliability

- [ ] **Multi-OS testing**. Developed on macOS 26.4 (Tahoe). `LSMinimumSystemVersion` is 14.0. Need to verify on:
  - macOS 14 (Sonoma) — minimum
  - macOS 15 (Sequoia)
  - macOS 26 (Tahoe) ✓ (current dev machine)
  Apple has been progressively locking down private APIs (we already hit this with `MRMediaRemoteGetNowPlayingApplicationIsPlaying`); each version may surface a regression.
- [ ] Multi-chip testing: M1, M2, M3, M4. Memory pressure for the Whisper model differs.
- [ ] Crash recovery. The daemon already restarts on exit, but bad transcriptions or audio errors should surface to the user instead of silently failing.
- [ ] Audio device change handling. If the user plugs in headphones mid-recording, we should reopen the input stream rather than hanging.
- [ ] Log rotation. `stt.log`, `app.log`, and `stt-app.log` grow forever. Cap at e.g. 5 × 1 MB rotated files.
- [ ] First-launch onboarding beyond permissions. Sample recording, mic test, "this is what it looks like when it works."

## Performance and packaging

- [ ] DMG size: 228 MB. App bundle: 897 MB. Trim:
  - Strip debug symbols from bundled `.so` / `.dylib` files (`strip -x`).
  - Drop unused MLX components if any.
  - Remove `tests/` and `__pycache__/` directories from site-packages (already strip __pycache__; broaden).
  - Consider removing `numba`/`scipy` if `mlx-whisper` works without them.
- [ ] Cold-start time. Model load takes ~5 s on first launch. Could pre-warm asynchronously after app launch instead of at first record.

## Cleanup

- [ ] **Delete `/overlay/` directory.** It contains a precompiled `voice-to-text-widget` binary with no source. The Swift app now provides the overlay; the binary is unused dead weight. `build.sh` already stopped copying it.
- [ ] **Delete `start_fn_listener` from `stt.py`.** Gated by an env var the Swift host always sets to skip it. Confirmed not callable in the production flow.
- [ ] Trim `requirements.txt`: `pyobjc-framework-Quartz` was added when Python owned the fn-key listener and is no longer used.

## Privacy, legal, distribution

- [ ] Privacy policy. Even with no telemetry, App Store and a public site need one.
- [ ] Terms of service / EULA.
- [ ] Marketing site (or at least a GitHub Pages landing page).
- [ ] Decide pricing model: free, paid, freemium, donation.
- [ ] Optional anonymous crash reports (opt-in). Sentry, Firebase Crashlytics, or self-hosted.

## Localization and accessibility

- [ ] Localize the menu, permissions window, and any future preferences UI.
- [ ] VoiceOver labels on the menu bar status item and any onscreen controls.
- [ ] High-contrast mode review for the orb visualizer.

## Stretch

- [ ] iCloud sync of preferences and custom vocabulary.
- [ ] Per-app vocabulary profiles (different terms in Slack vs Xcode).
- [ ] Dictation commands ("new paragraph", "period", "all caps that").
- [ ] Multiple recording slots (record several short clips before transcribing all together).
