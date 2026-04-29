import AppKit
import Foundation

/// Pauses any currently-playing system audio at the start of a recording and
/// resumes it on release. Uses Apple's private MediaRemote framework to detect
/// whether something is playing, then synthesizes a Play/Pause media key event
/// so the active media app (Spotify, Apple Music, Safari, Chrome, VLC, etc.)
/// reacts the same way it would if the user pressed the F8 key.
///
/// The MediaRemote APIs are a private framework; they've been stable for years
/// and every dictation app on the platform uses them. If Apple ever pulls
/// them, `pauseIfPlaying` becomes a no-op (the framework load returns nil) and
/// recording still works.
final class MediaController {
    private var didPauseForRecording = false

    /// If something is currently playing, send Play/Pause and remember that we
    /// paused. Returns immediately; the actual key event is dispatched on the
    /// caller's run loop after the async query resolves.
    func pauseIfPlaying() {
        Self.queryIsPlaying { [weak self] isPlaying in
            guard let self = self else { return }
            if isPlaying {
                Self.sendPlayPause()
                self.didPauseForRecording = true
                Log.write("MediaController: paused playing media")
            }
        }
    }

    /// If we paused something earlier, send Play/Pause again to resume it.
    func resumeIfWePaused() {
        guard didPauseForRecording else { return }
        didPauseForRecording = false
        Self.sendPlayPause()
        Log.write("MediaController: resumed media")
    }

    // MARK: - MediaRemote bridging

    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private static let getIsPlaying: GetIsPlayingFn? = {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url) else { return nil }
        let name = "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, name) else { return nil }
        return unsafeBitCast(ptr, to: GetIsPlayingFn.self)
    }()

    private static func queryIsPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let function = getIsPlaying else {
            // Private API isn't available — fail closed (don't pause anything).
            completion(false)
            return
        }
        function(DispatchQueue.main) { isPlaying in
            completion(isPlaying)
        }
    }

    // MARK: - Media key synthesis

    // NX_KEYTYPE_PLAY = 16 (from IOKit/hidsystem/IOLLEvent.h, deprecated header
    // that's still respected by every media app on macOS).
    private static let NX_KEYTYPE_PLAY = 16

    /// Sends both the down and up portions of a system Play/Pause key press.
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
