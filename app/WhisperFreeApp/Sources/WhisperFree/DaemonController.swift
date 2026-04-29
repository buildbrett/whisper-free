import Foundation

enum DaemonState {
    case running
    case restarting
    case stopped
}

final class DaemonController {
    private let queue = DispatchQueue(label: "com.local.whisperfree.daemon")
    private var process: Process?
    private var logHandle: FileHandle?
    private var shuttingDown = false
    private var restartAttempt = 0
    private var startedAt: Date?
    private var stableTimer: DispatchWorkItem?
    private let onStateChange: (DaemonState) -> Void

    init(onStateChange: @escaping (DaemonState) -> Void) {
        self.onStateChange = onStateChange
    }

    func start() {
        queue.async { [weak self] in self?.spawn() }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.restartAttempt = 0
            self.onStateChange(.restarting)
            self.killProcess(graceful: true)
            self.spawn()
        }
    }

    func shutdown() {
        queue.sync {
            shuttingDown = true
            stableTimer?.cancel()
            killProcess(graceful: true)
            onStateChange(.stopped)
        }
    }

    private func spawn() {
        guard !shuttingDown else { return }

        guard let resourcePath = Bundle.main.resourcePath else {
            onStateChange(.stopped)
            return
        }
        let pythonBin = "\(resourcePath)/python/bin/python3"
        let sttPy = "\(resourcePath)/stt.py"
        let overlayBin = "\(resourcePath)/overlay/voice-to-text-widget"

        let logURL = LogPaths.daemonLogFile
        try? FileManager.default.createDirectory(at: LogPaths.logDirectory,
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        // Append mode so we preserve history across restarts and across app launches.
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            onStateChange(.stopped)
            scheduleRestart()
            return
        }
        try? handle.seekToEnd()
        logHandle = handle

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonBin)
        task.arguments = [sttPy]
        task.standardOutput = handle
        task.standardError = handle

        var env: [String: String] = [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin",
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "WHISPER_OVERLAY_BIN": overlayBin
        ]
        let existing = ProcessInfo.processInfo.environment
        env["LANG"] = existing["LANG"] ?? "en_US.UTF-8"
        for (k, v) in existing where k.hasPrefix("WHISPER_") {
            env[k] = v
        }
        task.environment = env

        task.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleExit(proc) }
        }

        do {
            try task.run()
            process = task
            startedAt = Date()
            onStateChange(.running)
            scheduleStableReset()
        } catch {
            let msg = "[WhisperFree] failed to launch daemon: \(error)\n"
            if let data = msg.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
            onStateChange(.stopped)
            scheduleRestart()
        }
    }

    private func handleExit(_ proc: Process) {
        process = nil
        try? logHandle?.close()
        logHandle = nil
        stableTimer?.cancel()
        stableTimer = nil

        if shuttingDown { return }

        onStateChange(.restarting)
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delays: [Int] = [1, 2, 4, 8, 16, 32]
        let capped = min(restartAttempt, delays.count - 1)
        let delay = min(delays[capped], 30)
        restartAttempt += 1

        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            self?.spawn()
        }
    }

    private func scheduleStableReset() {
        // If the daemon stays up for 60s we consider the current run healthy and reset
        // the backoff counter so the next crash starts over from 1s.
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self = self else { return }
                if self.process != nil { self.restartAttempt = 0 }
            }
        }
        stableTimer = work
        queue.asyncAfter(deadline: .now() + .seconds(60), execute: work)
    }

    private func killProcess(graceful: Bool) {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }

        if graceful {
            kill(proc.processIdentifier, SIGTERM)
            let deadline = Date().addingTimeInterval(3.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            proc.waitUntilExit()
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
    }
}
