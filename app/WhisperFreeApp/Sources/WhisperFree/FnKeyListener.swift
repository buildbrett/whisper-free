import AppKit
import Darwin
import Foundation

/// Watches the configured push-to-talk key via NSEvent global monitors and
/// signals the daemon over its Unix socket. Handles both modifier keys (Right
/// Option, Right Shift, etc., via .flagsChanged) and function keys (F13-F20,
/// via .keyDown / .keyUp). Caps Lock is treated as a press-to-toggle.
///
/// The Globe (fn) key is deliberately not supported here: macOS filters it
/// out of every userspace event observation API.
final class KeyListener {
    private let socketPath: String
    private var key: PushToTalkKey
    private var globalFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var isDown = false
    private var capsLockOn = false
    private var clientSocket: Int32 = -1
    private let media: MediaController

    init(socketPath: String, key: PushToTalkKey, media: MediaController) {
        self.socketPath = socketPath
        self.key = key
        self.media = media
    }

    var isInactive: Bool { globalFlagsMonitor == nil }

    /// Switch which key triggers push-to-talk. If recording is currently active
    /// we send a stop first to avoid an orphaned recording.
    func setKey(_ newKey: PushToTalkKey) {
        if newKey == key { return }
        Log.write("KeyListener.setKey: \(key.displayName) → \(newKey.displayName)")
        if isDown {
            send("stop")
            isDown = false
        }
        key = newKey
        capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
    }

    func start() -> Bool {
        guard globalFlagsMonitor == nil else {
            Log.write("KeyListener.start: already running")
            return true
        }

        clientSocket = socket(AF_UNIX, SOCK_DGRAM, 0)
        capsLockOn = NSEvent.modifierFlags.contains(.capsLock)

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event, down: true)
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleKeyEvent(event, down: false)
        }

        let ok = globalFlagsMonitor != nil
        Log.write("KeyListener.start: monitors installed=\(ok), key=\(key.displayName), socket=\(clientSocket)")
        return ok
    }

    func stop() {
        for m in [globalFlagsMonitor, globalKeyDownMonitor, globalKeyUpMonitor] {
            if let m = m { NSEvent.removeMonitor(m) }
        }
        globalFlagsMonitor = nil
        globalKeyDownMonitor = nil
        globalKeyUpMonitor = nil
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        if isDown {
            isDown = false
        }
    }

    // MARK: - Event handling

    private func handleFlagsChanged(_ event: NSEvent) {
        guard key.isModifier, event.keyCode == key.keyCode else { return }

        if key == .capsLock {
            // Caps Lock toggles state on each press. Use the LED state (the
            // .capsLock flag) as the source of truth.
            let nowOn = event.modifierFlags.contains(.capsLock)
            if nowOn == capsLockOn { return }
            capsLockOn = nowOn
            startOrStopRecording(start: nowOn)
            return
        }

        // Hold-to-record for other modifiers. The relevant flag bit is high
        // while either left or right side is held; combined with the keyCode
        // check above, this correctly tracks the right-side key in the common
        // case.
        guard let flag = key.modifierFlag else { return }
        let down = event.modifierFlags.contains(flag)
        if down == isDown { return }
        isDown = down
        startOrStopRecording(start: down)
    }

    private func handleKeyEvent(_ event: NSEvent, down: Bool) {
        guard !key.isModifier, event.keyCode == key.keyCode else { return }
        if down == isDown { return }
        isDown = down
        startOrStopRecording(start: down)
    }

    // MARK: - Recording transitions

    private func startOrStopRecording(start: Bool) {
        if start {
            // Pause any currently-playing media before recording so speaker
            // output doesn't bleed into the microphone input.
            media.pauseIfPlaying()
        }
        send(start ? "start" : "stop")
        if !start {
            media.resumeIfWePaused()
        }
    }

    // MARK: - Socket send

    private func send(_ message: String) {
        guard clientSocket >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.count <= maxLen else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<path.count { dst[i] = path[i] }
            }
        }
        let data = Array(message.utf8)
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let sent: ssize_t = data.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(clientSocket, buf.baseAddress, buf.count, 0, sa, addrLen)
                }
            }
        }
        if sent < 0 {
            Log.write("KeyListener.send: sendto errno=\(errno) for '\(message)'")
        }
    }
}
