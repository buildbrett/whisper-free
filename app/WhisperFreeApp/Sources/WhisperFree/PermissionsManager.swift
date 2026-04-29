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
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:    return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    var reason: String {
        switch self {
        case .microphone:
            return "Records audio while your push-to-talk key is held."
        case .accessibility:
            return "Detects your push-to-talk key and pastes transcribed text into the active app."
        }
    }

    var settingsURL: URL {
        let anchor: String
        switch self {
        case .microphone:    anchor = "Privacy_Microphone"
        case .accessibility: anchor = "Privacy_Accessibility"
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
        case .accessibility:
            // The Accessibility API shows a system alert the first time per app
            // identity; after that it silently returns the cached state. It's also
            // synchronous and can block briefly while macOS prepares the prompt —
            // so we run it off the main thread and open Settings in parallel so
            // the user always has a visible next step.
            NSWorkspace.shared.open(p.settingsURL)
            DispatchQueue.global(qos: .userInitiated).async {
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                let granted = AXIsProcessTrustedWithOptions(opts)
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
