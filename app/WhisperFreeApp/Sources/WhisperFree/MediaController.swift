import AppKit
import CoreAudio
import Foundation

/// Pauses any currently-playing system audio at the start of a recording and
/// resumes it on release.
///
/// Detection: we ask CoreAudio whether the default output device is running
/// (`kAudioDevicePropertyDeviceIsRunningSomewhere`). That property is true
/// whenever any process is sending audio to the speakers — Apple Music,
/// Spotify, Safari, Chrome, YouTube, VLC, podcast apps, system sounds.
///
/// Pausing: we synthesize a Play/Pause media key event (the same one your
/// keyboard's F8 sends). Anything that registers with the system media key
/// listener — which is essentially every media app on macOS — reacts.
///
/// We previously used Apple's private MediaRemote framework for the detection
/// step. On macOS 26+ that framework's `IsPlaying` query returns false for
/// non-entitled apps even when audio is active, so it's unreliable. The
/// CoreAudio path is public and works regardless of macOS version.
final class MediaController {
    private var didPauseForRecording = false

    /// If something is currently playing, send Play/Pause and remember that
    /// we paused.
    func pauseIfPlaying() {
        guard Self.isOutputActive() else { return }
        Self.sendPlayPause()
        didPauseForRecording = true
        Log.write("MediaController: paused playing media")
    }

    /// If we paused something earlier, send Play/Pause again to resume it.
    func resumeIfWePaused() {
        guard didPauseForRecording else { return }
        didPauseForRecording = false
        Self.sendPlayPause()
        Log.write("MediaController: resumed media")
    }

    // MARK: - Output activity detection

    private static func isOutputActive() -> Bool {
        var deviceID: AudioDeviceID = 0
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let lookup = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &propSize, &deviceID
        )
        guard lookup == noErr, deviceID != 0 else { return false }

        var isRunning: UInt32 = 0
        propSize = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let query = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &propSize, &isRunning)
        return query == noErr && isRunning != 0
    }

    // MARK: - Media key synthesis

    // NX_KEYTYPE_PLAY = 16 (from IOKit/hidsystem/IOLLEvent.h, deprecated header
    // that's still respected by every media app on macOS).
    private static let NX_KEYTYPE_PLAY = 16

    private static func sendPlayPause() {
        post(keyType: NX_KEYTYPE_PLAY, isDown: true)
        post(keyType: NX_KEYTYPE_PLAY, isDown: false)
    }

    private static func post(keyType: Int, isDown: Bool) {
        let stateBits = isDown ? 0xa : 0xb
        let data1 = (keyType << 16) | (stateBits << 8)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(stateBits) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cgSessionEventTap)
    }
}
