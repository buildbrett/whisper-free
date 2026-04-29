import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var daemon: DaemonController!
    private var statusMenuItem: NSMenuItem!
    private var permissionsMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionsPollTimer: Timer?
    private var lastDaemonState: DaemonState = .stopped
    private var lastAllGranted: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateStatusIcon()

        daemon = DaemonController { [weak self] state in
            DispatchQueue.main.async {
                self?.lastDaemonState = state
                self?.updateStatusLabel(state)
                self?.updateStatusIcon()
            }
        }
        daemon.start()

        installSignalHandlers()
        lastAllGranted = PermissionsManager.allGranted
        startPermissionsPolling()

        if !PermissionsManager.allGranted {
            // Defer briefly so the status item is visible before the window covers it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PermissionsWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionsPollTimer?.invalidate()
        daemon?.shutdown()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "Whisper Free", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        header.attributedTitle = NSAttributedString(string: "Whisper Free", attributes: [.font: font])
        menu.addItem(header)

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        permissionsMenuItem = NSMenuItem(title: "Permissions…",
                                         action: #selector(openPermissions),
                                         keyEquivalent: "")
        menu.addItem(permissionsMenuItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Logs Folder",
                                action: #selector(openLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart Daemon",
                                action: #selector(restartDaemon), keyEquivalent: ""))

        loginItemMenuItem = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLoginItem), keyEquivalent: "")
        menu.addItem(loginItemMenuItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Whisper Free",
                              action: #selector(quit), keyEquivalent: "q")
        menu.addItem(quit)

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItemMenuItem.state = LoginItem.isEnabled ? .on : .off
        refreshPermissionsMenuLabel()
    }

    private func refreshPermissionsMenuLabel() {
        let missing = PermissionsManager.missing
        if missing.isEmpty {
            permissionsMenuItem.title = "Permissions ✓"
        } else {
            let names = missing.map { $0.title }.joined(separator: ", ")
            permissionsMenuItem.title = "⚠ Permissions needed: \(names)"
        }
    }

    private func updateStatusLabel(_ state: DaemonState) {
        switch state {
        case .running: statusMenuItem.title = "Status: Running"
        case .restarting: statusMenuItem.title = "Status: Restarting…"
        case .stopped: statusMenuItem.title = "Status: Stopped"
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let allGranted = PermissionsManager.allGranted
        let symbol = allGranted ? "mic" : "mic.slash"
        let description = allGranted ? "Whisper Free" : "Whisper Free — permissions needed"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = allGranted ? nil : "Whisper Free needs permissions — click for details"
    }

    private func startPermissionsPolling() {
        permissionsPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkPermissionsFlip()
        }
    }

    private func checkPermissionsFlip() {
        updateStatusIcon()
        let now = PermissionsManager.allGranted
        defer { lastAllGranted = now }
        if now && !lastAllGranted {
            // The daemon's CGEventTap was created before the grant existed and
            // won't retroactively start receiving events. Restart it.
            daemon?.restart()
        }
    }

    @objc private func openPermissions() {
        PermissionsWindowController.shared.show()
    }

    @objc private func openLogs() {
        let url = LogPaths.logDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func restartDaemon() {
        daemon.restart()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.toggle()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        loginItemMenuItem.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func quit() {
        daemon.shutdown()
        NSApp.terminate(nil)
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.daemon.shutdown()
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

enum LogPaths {
    static var logDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/whisper-free", isDirectory: true)
    }

    static var daemonLogFile: URL {
        logDirectory.appendingPathComponent("stt-app.log")
    }
}
