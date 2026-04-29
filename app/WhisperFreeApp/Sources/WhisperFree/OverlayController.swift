import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

/// Floating overlay shown during recording and transcription. Hosts a glowing
/// orb whose pulse and glow track the live audio level the daemon publishes
/// over a Unix socket.
///
/// The daemon is unchanged: it sends the same messages it used to send to the
/// precompiled `voice-to-text-widget` binary. We bind that socket here so the
/// daemon's "is anything listening?" check succeeds and it never tries to
/// launch the old binary.
final class OverlayController {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let panel: OverlayPanel
    private let state: OverlayState

    init(socketPath: String = "/tmp/whisper_overlay.sock") {
        self.socketPath = socketPath
        let s = MainActor.assumeIsolated { OverlayState() }
        self.state = s
        self.panel = MainActor.assumeIsolated { OverlayPanel(state: s) }
    }

    func start() {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.write("OverlayController: socket() failed errno=\(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.count <= maxLen else {
            Log.write("OverlayController: socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for i in 0..<path.count { dst[i] = path[i] }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindResult != 0 {
            Log.write("OverlayController: bind failed errno=\(errno)")
            close(fd)
            return
        }
        chmod(socketPath, 0o777)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.readDatagrams()
        }
        source.resume()
        readSource = source

        Log.write("OverlayController.start: listening on \(socketPath)")
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Receive

    private func readDatagrams() {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { buf in
                recv(listenFD, buf.baseAddress, buf.count, MSG_DONTWAIT)
            }
            if n <= 0 { return }
            guard let message = String(bytes: buffer.prefix(Int(n)), encoding: .utf8) else { continue }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handle(message) }
            }
        }
    }

    @MainActor
    private func handle(_ message: String) {
        if message == "ping" { return }

        if message.hasPrefix("level:") {
            let raw = message.dropFirst("level:".count)
            if let value = Double(raw) {
                state.level = max(0, min(1, value))
            }
            return
        }

        switch message {
        case "recording_start":
            state.phase = .recording
            state.level = 0
            panel.show()
        case "recording_stop":
            state.phase = .idle
            panel.hide()
        case "transcribing_start":
            state.phase = .transcribing
            state.level = 0
        case "transcribing_done":
            state.phase = .idle
            panel.hide()
        default:
            Log.write("OverlayController: unknown message '\(message)'")
        }
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var phase: OverlayController.Phase = .idle
    @Published var level: Double = 0
}

// MARK: - Panel

@MainActor
private final class OverlayPanel {
    private let panel: NSPanel
    private let state: OverlayState

    init(state: OverlayState) {
        self.state = state

        let size = NSSize(width: 160, height: 160)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let host = NSHostingController(rootView: OverlayContent(state: state))
        host.view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host.view

        positionAtScreenBottom()
    }

    func show() {
        positionAtScreenBottom()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionAtScreenBottom() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 40
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Visualizer view
//
// Vendored Orb (https://github.com/metasidd/Orb, MIT) ported to native macOS.
// Driven by audio level via scale + brightness modulation on the outer
// container; the Orb itself is autonomous (its internal animations would reset
// if we re-instantiated it on every level update, so we keep its config fixed
// and modulate around it).

private struct OverlayContent: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        OrbVisualizer(phase: state.phase, level: state.level)
            .opacity(state.phase == .idle ? 0 : 1)
            .animation(.easeInOut(duration: 0.3), value: state.phase)
    }
}

private struct OrbVisualizer: View {
    let phase: OverlayController.Phase
    let level: Double

    @State private var smoothedLevel: Double = 0

    var body: some View {
        ZStack {
            // Radial halo: a circle with a RadialGradient that fades to clear,
            // so its edges are naturally round (no rectangular leakage). Scale
            // and opacity track audio level so loud speech reads as a brighter,
            // larger glow.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [haloColor.opacity(0.85), haloColor.opacity(0.0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60
                    )
                )
                .frame(width: 120, height: 120)
                .scaleEffect(0.7 + smoothedLevel * 0.6)
                .opacity(0.4 + smoothedLevel * 0.7)
                .blur(radius: 6)

            // The orb itself, with extra saturation and a level-reactive scale.
            OrbView(configuration: configuration)
                .frame(width: 50, height: 50)
                .saturation(phase == .transcribing ? 0.75 : 1.35)
                .brightness(smoothedLevel * 0.08)
                .scaleEffect(1.0 + smoothedLevel * 0.45)
        }
        .frame(width: 120, height: 120)
        .onChange(of: level) { newLevel in
            withAnimation(.easeOut(duration: 0.08)) {
                smoothedLevel = smoothedLevel * 0.6 + newLevel * 0.4
            }
        }
    }

    private var haloColor: Color {
        switch phase {
        case .idle, .recording:
            return Color(red: 0.55, green: 0.55, blue: 1.0)
        case .transcribing:
            return Color(red: 0.30, green: 0.90, blue: 0.65)
        }
    }

    private var configuration: OrbConfiguration {
        switch phase {
        case .idle, .recording:
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 0.95, green: 0.30, blue: 0.55),  // deep pink
                    Color(red: 0.30, green: 0.40, blue: 1.00),  // saturated blue
                    Color(red: 0.20, green: 0.85, blue: 0.85)   // bright teal
                ],
                glowColor: .white,
                coreGlowIntensity: 1.1,
                showShadow: false,
                speed: 70
            )
        case .transcribing:
            return OrbConfiguration(
                backgroundColors: [
                    Color(red: 0.20, green: 0.85, blue: 0.55),
                    Color(red: 0.10, green: 0.65, blue: 0.45)
                ],
                glowColor: .white,
                coreGlowIntensity: 0.85,
                showShadow: false,
                speed: 40
            )
        }
    }
}
