import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var daemon: DaemonController!
    private var statusMenuItem: NSMenuItem!
    private var permissionsMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!
    private var pauseMediaMenuItem: NSMenuItem!
    private var pttSubmenu: NSMenu!
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionsPollTimer: Timer?
    private var lastDaemonState: DaemonState = .stopped
    private var lastAllGranted: Bool = false
    private let media = MediaController()
    private lazy var keyListener = KeyListener(socketPath: "/tmp/whisper_free.sock",
                                               key: Settings.pushToTalkKey,
                                               media: media)
    private let overlay = OverlayController()

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
        Log.write("App did finish launching. allGranted=\(lastAllGranted), bundlePath=\(Bundle.main.bundlePath)")
        overlay.start()
        let started = keyListener.start()
        Log.write("Initial keyListener.start() returned \(started)")
        startPermissionsPolling()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionsChanged),
            name: .whisperPermissionsChanged,
            object: nil
        )

        if !PermissionsManager.allGranted {
            // Defer briefly so the status item is visible before the window covers it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                PermissionsWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionsPollTimer?.invalidate()
        overlay.stop()
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

        pauseMediaMenuItem = NSMenuItem(title: "Pause Media During Recording",
                                        action: #selector(togglePauseMedia),
                                        keyEquivalent: "")
        menu.addItem(pauseMediaMenuItem)

        let pttItem = NSMenuItem(title: "Push-to-talk Key", action: nil, keyEquivalent: "")
        pttSubmenu = NSMenu()
        for k in PushToTalkKey.allCases {
            let item = NSMenuItem(title: k.displayName,
                                  action: #selector(selectPushToTalkKey(_:)),
                                  keyEquivalent: "")
            item.representedObject = k.rawValue
            item.target = self
            pttSubmenu.addItem(item)
        }
        pttItem.submenu = pttSubmenu
        menu.addItem(pttItem)

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
        pauseMediaMenuItem.state = Settings.pauseMediaDuringRecording ? .on : .off
        refreshPermissionsMenuLabel()
        let current = Settings.pushToTalkKey
        for item in pttSubmenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == current.rawValue) ? .on : .off
            }
        }
    }

    @objc private func togglePauseMedia() {
        Settings.pauseMediaDuringRecording.toggle()
        pauseMediaMenuItem.state = Settings.pauseMediaDuringRecording ? .on : .off
    }

    @objc private func selectPushToTalkKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = PushToTalkKey(rawValue: raw) else { return }
        Settings.pushToTalkKey = key
        keyListener.setKey(key)
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

    @objc private func permissionsChanged() {
        checkPermissionsFlip()
    }

    private func checkPermissionsFlip() {
        updateStatusIcon()
        let now = PermissionsManager.allGranted
        defer { lastAllGranted = now }
        if now && !lastAllGranted {
            keyListener.stop()
            _ = keyListener.start()
            daemon?.restart()
        } else if now && keyListener.isInactive {
            _ = keyListener.start()
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
