import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

enum Permission: String, CaseIterable, Identifiable {
    case microphone
    case inputMonitoring
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:      return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility:   return "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone:
            return "Records audio while you hold the Globe key."
        case .inputMonitoring:
            return "Detects when you press and release the Globe key."
        case .accessibility:
            return "Pastes transcribed text into the app you're using."
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone:      anchor = "Privacy_Microphone"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility:   anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

enum PermissionsManager {
    static func status(for p: Permission) -> PermissionStatus {
        switch p {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        case .inputMonitoring:
            // CGPreflight returns true only when granted. The system doesn't expose a
            // distinct "denied" state here, so everything else falls into .notDetermined.
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        }
    }

    static func request(_ p: Permission, completion: @escaping (PermissionStatus) -> Void) {
        switch p {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        case .inputMonitoring, .accessibility:
            // These APIs show a system prompt the first time per app identity; after
            // that they silently return the cached state. They're also synchronous and
            // can block for seconds while macOS prepares the prompt — so we run them
            // off the main thread and open Settings in parallel so the user always has
            // a visible next step.
            NSWorkspace.shared.open(p.settingsURL)
            DispatchQueue.global(qos: .userInitiated).async {
                let granted: Bool
                switch p {
                case .inputMonitoring:
                    granted = CGRequestListenEventAccess()
                case .accessibility:
                    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    granted = AXIsProcessTrustedWithOptions(opts)
                default:
                    granted = false
                }
                DispatchQueue.main.async {
                    completion(granted ? .granted : .notDetermined)
                }
            }
        }
    }

    static func openSettings(for p: Permission) {
        NSWorkspace.shared.open(p.settingsURL)
    }

    static var allGranted: Bool {
        Permission.allCases.allSatisfy { status(for: $0) == .granted }
    }

    static var missing: [Permission] {
        Permission.allCases.filter { status(for: $0) != .granted }
    }
}
