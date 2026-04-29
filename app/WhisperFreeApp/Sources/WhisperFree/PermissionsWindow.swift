import AppKit
import SwiftUI

final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PermissionsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: PermissionsView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Whisper Free"
        window.setContentSize(NSSize(width: 520, height: 520))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func show() {
        // Accessory apps cannot take foreground focus. Flip to regular for
        // the duration the window is visible, then flip back on close.
        NSApp.setActivationPolicy(.regular)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct PermissionsView: View {
    @State private var statuses: [Permission: PermissionStatus] = [:]
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Whisper Free")
                    .font(.title2).fontWeight(.semibold)
                Text("Grant these permissions so push-to-talk works. You can reopen this window any time from the menu bar.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(Permission.allCases) { p in
                    PermissionRow(
                        permission: p,
                        status: statuses[p] ?? .notDetermined,
                        onRequest: { request(p) },
                        onOpenSettings: { PermissionsManager.openSettings(for: p) }
                    )
                }
            }

            if statuses.values.contains(where: { $0 != .granted }) {
                Text("macOS only shows its prompt the first time. If clicking Grant does nothing, use Open Settings and toggle Whisper Free on.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Recheck") { refresh() }
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520, alignment: .topLeading)
        .onAppear {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                refresh()
            }
        }
        .onDisappear { pollTimer?.invalidate() }
    }

    private func refresh() {
        var snapshot: [Permission: PermissionStatus] = [:]
        for p in Permission.allCases {
            snapshot[p] = PermissionsManager.status(for: p)
        }
        statuses = snapshot
    }

    private func request(_ p: Permission) {
        PermissionsManager.request(p) { _ in refresh() }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).fontWeight(.medium)
                Text(permission.reason)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status == .granted {
                Text("Granted").foregroundColor(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Grant", action: onRequest)
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.title2)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.title2)
        case .notDetermined:
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange).font(.title2)
        }
    }
}
