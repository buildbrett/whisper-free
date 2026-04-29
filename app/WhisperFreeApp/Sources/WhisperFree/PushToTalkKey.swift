import AppKit
import Foundation

/// All keys we can use as the push-to-talk trigger. Globe (fn) is intentionally
/// absent: macOS filters fn out of every userspace event observation API, so
/// reliably catching it would require a kernel-level driver (e.g. Karabiner).
enum PushToTalkKey: String, CaseIterable, Identifiable {
    case capsLock
    case rightOption
    case rightCommand
    case rightShift
    case rightControl
    case f13, f14, f15, f16, f17, f18, f19, f20

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .capsLock:     return "Caps Lock (toggle)"
        case .rightOption:  return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightShift:   return "Right Shift (⇧)"
        case .rightControl: return "Right Control (⌃)"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .f20: return "F20"
        }
    }

    /// Caps Lock is a toggle key (press once to lock, press again to unlock); we
    /// inherit that semantics. Everything else is hold-to-record.
    var isToggle: Bool { self == .capsLock }

    var isModifier: Bool {
        switch self {
        case .capsLock, .rightOption, .rightCommand, .rightShift, .rightControl:
            return true
        default:
            return false
        }
    }

    /// Hardware keyCode (kVK_*).
    var keyCode: UInt16 {
        switch self {
        case .capsLock:     return 57
        case .rightCommand: return 54
        case .rightShift:   return 60
        case .rightOption:  return 61
        case .rightControl: return 62
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        case .f20: return 90
        }
    }

    /// For modifier keys, which NSEvent flag bit goes high while the key is held.
    var modifierFlag: NSEvent.ModifierFlags? {
        switch self {
        case .rightOption:  return .option
        case .rightCommand: return .command
        case .rightShift:   return .shift
        case .rightControl: return .control
        case .capsLock:     return .capsLock
        default:            return nil
        }
    }
}

enum Settings {
    private static let pttKey = "pushToTalkKey"
    private static let didShowOnboardingKey = "didShowPermissionsOnboarding"

    static var pushToTalkKey: PushToTalkKey {
        get {
            if let raw = UserDefaults.standard.string(forKey: pttKey),
               let k = PushToTalkKey(rawValue: raw) {
                return k
            }
            return .capsLock
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pttKey) }
    }
}
