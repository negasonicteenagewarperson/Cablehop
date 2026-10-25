import AppKit
import os

/// App-wide logging. Everything goes to two places, both only on this Mac:
/// - macOS's unified log (visible in Console.app, subsystem `app.cablehop.Cablehop`)
/// - plain-text files in ~/Library/Logs/Cablehop, which Settings can show and save for bug reports.
///
/// Nothing is ever sent anywhere. Paths inside your home folder are written as "~/…".
enum Log {
    enum Level: String, Comparable {
        case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR"

        private var rank: Int { [.debug: 0, .info: 1, .warning: 2, .error: 3][self]! }
        static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    enum Category: String {
        case app, device, mtp, adb, transfer, files, sync, wireless, update
    }

    static func debug(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.debug, category, message()) }
    static func info(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.info, category, message()) }
    static func warning(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.warning, category, message()) }
    static func error(_ message: @autoclosure () -> String, _ category: Category = .app) { write(.error, category, message()) }

    private static func write(_ level: Level, _ category: Category, _ message: String) {
        let clean = LogStore.redact(message)
        let logger = Logger(subsystem: LogStore.subsystem, category: category.rawValue)
        switch level {
        case .debug: logger.debug("\(clean, privacy: .public)")
        case .info: logger.info("\(clean, privacy: .public)")
        case .warning: logger.warning("\(clean, privacy: .public)")
        case .error: logger.error("\(clean, privacy: .public)")
        }
        LogStore.shared.append(level: level, category: category, message: clean)
    }
}

/// The on-disk log files: `Cablehop.log` plus up to four older ones (`Cablehop.1.log` … `.4.log`),
/// each capped at 2 MB, so logs never take more than about 10 MB.
final class LogStore: @unchecked Sendable {
    /// The real logs, or a throwaway folder while the unit tests run (so tests never touch your logs).
    static let shared = isRunningTests
        ? LogStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CablehopTestLogs-\(UUID().uuidString)"))
        : LogStore()

    static var isRunningTests: Bool {
        let name = ProcessInfo.processInfo.processName
        return name == "xctest" || name.contains("swiftpm-testing-helper") || Bundle.main.bundlePath.hasSuffix(".xctest")
            || NSClassFromString("XCTestCase") != nil
    }
    static let subsystem = "app.cablehop.Cablehop"

    let directory: URL
    private let maxFileSize: UInt64 = 2 * 1024 * 1024
    private let maxOldFiles = 4
    private let queue = DispatchQueue(label: "Cablehop.log")
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0

    // ISO8601DateFormatter is documented as thread-safe.
    nonisolated(unsafe) private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    init(directory: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Cablehop", isDirectory: true)) {
        self.directory = directory
    }

    var currentFile: URL { directory.appendingPathComponent("Cablehop.log") }
    private func oldFile(_ n: Int) -> URL { directory.appendingPathComponent("Cablehop.\(n).log") }

    /// All log files, oldest first.
    var files: [URL] {
        ((1...maxOldFiles).reversed().map(oldFile) + [currentFile]).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The last line written, so a message repeating every second (e.g. a device check failing) is
    /// collapsed into one line plus a count instead of filling the logs.
    private var lastMessage = ""
    private var repeats = 0

    func append(level: Log.Level, category: Log.Category, message: String) {
        let now = Date()
        queue.async {
            let key = "\(level.rawValue)|\(category.rawValue)|\(message)"
            if key == self.lastMessage {
                self.repeats += 1
                return
            }
            if self.repeats > 0 {
                let note = "\(Self.timestamp.string(from: now)) [INFO] [app] (previous message repeated \(self.repeats) more time\(self.repeats == 1 ? "" : "s"))\n"
                self.write(Data(note.utf8))
                self.repeats = 0
            }
            self.lastMessage = key
            let line = "\(Self.timestamp.string(from: now)) [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
            self.write(Data(line.utf8))
        }
    }

    /// Waits until everything logged so far is on disk.
    func flush() { queue.sync {} }

    private func write(_ data: Data) {
        if handle == nil { openFile() }
        guard let handle else { return }
        if currentSize > 0 && currentSize + UInt64(data.count) > maxFileSize {
            rotate()
            return write(data)
        }
        do {
            try handle.write(contentsOf: data)
            currentSize += UInt64(data.count)
        } catch {
            self.handle = nil  // reopen next time (e.g. the file was deleted)
        }
    }

    private func openFile() {
        let fm = FileManager.default
        // Logs are private: only your user account can read them.
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: currentFile.path) {
            fm.createFile(atPath: currentFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: currentFile)
        currentSize = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: oldFile(maxOldFiles))
        for n in stride(from: maxOldFiles - 1, through: 1, by: -1) {
            try? fm.moveItem(at: oldFile(n), to: oldFile(n + 1))
        }
        try? fm.moveItem(at: currentFile, to: oldFile(1))
        openFile()
    }

    /// Everything in the log files, oldest first.
    func contents() -> String {
        flush()
        return queue.sync {
            files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        }
    }

    func clear() {
        queue.sync {
            try? handle?.close()
            handle = nil
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        append(level: .info, category: .app, message: "Logs cleared")
    }

    /// The full report saved for bug reports: details about the app and Mac, then every log line.
    func exportText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "development build"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let header = """
        Cablehop logs
        Saved: \(Self.timestamp.string(from: Date()))
        Cablehop version: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Mac model: \(String(cString: model)) (\(Self.architecture))
        adb: \(ADB.path == nil ? "not installed" : "installed")
        ----------------------------------------------------------------

        """
        return header + contents()
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple silicon"
        #else
        return "Intel"
        #endif
    }

    /// Keeps your Mac username out of logs.
    static func redact(_ message: String) -> String {
        message.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Suggested file name for a saved log, e.g. "Cablehop logs 2026-10-25 19.30.txt".
    static var exportFileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "Cablehop logs \(f.string(from: Date())).txt"
    }

    /// Shows a save panel and writes the full log report. Returns where it was saved.
    @MainActor @discardableResult
    static func saveWithPanel() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = exportFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.message = "Logs stay on your Mac unless you share this file. They may include phone file and folder names."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try shared.exportText().write(to: url, atomically: true, encoding: .utf8)
            Log.info("Logs saved for sharing")
            return url
        } catch {
            Log.error("Couldn't save logs: \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            alert.runModal()
            return nil
        }
    }
}
