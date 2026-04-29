import Foundation

/// File-backed logger. The Swift app has no usable stdout when launched via
/// `open` (Finder/launchd), so everything we want to debug has to land on disk.
enum Log {
    private static let queue = DispatchQueue(label: "com.local.whisperfree.log")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var logURL: URL {
        LogPaths.logDirectory.appendingPathComponent("app.log")
    }

    static func write(_ message: String) {
        queue.async {
            try? FileManager.default.createDirectory(at: LogPaths.logDirectory, withIntermediateDirectories: true)
            let line = "\(dateFormatter.string(from: Date())) [app] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let url = logURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}
