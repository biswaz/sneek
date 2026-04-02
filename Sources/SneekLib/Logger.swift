import Foundation

public enum SneekLogger {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warn, error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    public nonisolated(unsafe) static var level: Level = .info
    public nonisolated(unsafe) static var logFile: URL?

    private static let queue = DispatchQueue(label: "com.sneek.logger")
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func log(_ level: Level, _ message: String) {
        guard level >= self.level else { return }
        let timestamp = iso8601.string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] \(message)\n"

        if level >= .warn {
            FileHandle.standardError.write(Data(line.utf8))
        }

        guard let logFile = logFile else { return }
        queue.async {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile()
                fh.write(Data(line.utf8))
                fh.closeFile()
            } else {
                FileManager.default.createFile(atPath: logFile.path, contents: Data(line.utf8))
            }
        }
    }

    public static func debug(_ message: String) { log(.debug, message) }
    public static func info(_ message: String) { log(.info, message) }
    public static func warn(_ message: String) { log(.warn, message) }
    public static func error(_ message: String) { log(.error, message) }
}
