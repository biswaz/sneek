import Foundation

// MARK: - Weak Reference Helper

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

// MARK: - Session Manager

public actor SessionManager {

    struct LiveSession {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let sentinel: String
        var lastUsed: Date
    }

    private var sessions: [String: LiveSession] = [:]
    private var idleTimers: [String: DispatchSourceTimer] = [:]

    public init() {}

    // MARK: - Session mode

    public func send(input: String, to name: String, config: CommandConfig, resolvedCommand: String) async throws -> String {
        if config.readonly == true, let patterns = config.blockedPatterns {
            let upper = input.uppercased()
            for pattern in patterns {
                if upper.contains(pattern.uppercased()) {
                    SneekLogger.warn("session/\(name): blocked input matching pattern '\(pattern)'")
                    throw SessionError.blockedByReadonly(pattern: pattern, input: input)
                }
            }
        }

        if sessions[name] == nil {
            try await startSession(name: name, command: resolvedCommand, config: config)
        }

        guard var session = sessions[name] else {
            throw SessionError.sessionNotFound(name)
        }

        let sentinel = session.sentinel

        // Write input + sentinel to stdin
        let payload = input + "\n" + sentinel + "\n"
        session.stdin.write(Data(payload.utf8))

        // Read until sentinel appears in output
        let output = try await readUntilSentinel(from: session.stdout, sentinel: sentinel)

        session.lastUsed = Date()
        sessions[name] = session
        resetIdleTimer(name: name, timeout: config.idleTimeout ?? 300)

        return output
    }

    // MARK: - Oneshot mode

    public func runOneshot(command: String, input: String?) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", input.map { "\(command) \(shellEscape($0))" } ?? command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw SessionError.processExited(code: process.terminationStatus, stderr: stderr)
        }

        return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Lifecycle

    public func reap(_ name: String) {
        if let session = sessions[name] {
            session.process.terminate()
            sessions.removeValue(forKey: name)
            SneekLogger.info("session/\(name): reaped")
        }
        idleTimers[name]?.cancel()
        idleTimers.removeValue(forKey: name)
    }

    public func reapAll() {
        for (name, _) in sessions {
            reap(name)
        }
    }

    public func activeSessions() -> [String] {
        Array(sessions.keys)
    }

    // MARK: - Private

    private func startSession(name: String, command: String, config: CommandConfig) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe  // merge stderr into stdout so errors are visible

        try process.run()

        let sentinel = config.sentinel ?? defaultSentinel(for: command)

        let session = LiveSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            sentinel: sentinel,
            lastUsed: Date()
        )

        // Run setup commands — fail session if any produces error output
        if let setupCmds = config.setupCommands {
            for cmd in setupCmds {
                let payload = cmd + "\n" + sentinel + "\n"
                session.stdin.write(Data(payload.utf8))
                let output = try await readUntilSentinel(from: session.stdout, sentinel: sentinel)
                if !output.isEmpty {
                    let lower = output.lowercased()
                    if lower.contains("error") || lower.contains("fatal") || lower.contains("denied") {
                        process.terminate()
                        throw SessionError.setupCommandFailed(command: cmd, output: output)
                    }
                }
            }
        }

        sessions[name] = session
        resetIdleTimer(name: name, timeout: config.idleTimeout ?? 300)
        SneekLogger.info("session/\(name): started")
    }

    /// The sentinel marker that appears in command output.
    /// The sentinel *command* (e.g., `echo __SNEEK_DONE__`) produces this *output*.
    private static let sentinelOutput = "__SNEEK_DONE__"

    private func readUntilSentinel(from handle: FileHandle, sentinel: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var accumulated = ""

                while true {
                    let data = handle.availableData
                    if data.isEmpty {
                        continuation.resume(throwing: SessionError.processExited(code: -1, stderr: "EOF"))
                        return
                    }
                    guard let chunk = String(data: data, encoding: .utf8) else { continue }
                    accumulated += chunk

                    // Check if sentinel output appeared
                    let lines = accumulated.components(separatedBy: "\n")
                    if let idx = lines.lastIndex(where: { $0.contains(Self.sentinelOutput) }) {
                        let output = lines[..<idx].joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: output)
                        return
                    }
                }
            }
        }
    }

    private func resetIdleTimer(name: String, timeout: Int) {
        idleTimers[name]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(timeout))
        let weakSelf = WeakRef(self)
        timer.setEventHandler {
            Task { await weakSelf.value?.reap(name) }
        }
        timer.resume()
        idleTimers[name] = timer
    }

    private func defaultSentinel(for command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("psql") {
            return #"\echo __SNEEK_DONE__"#
        } else if lower.contains("mysql") {
            return "SELECT '__SNEEK_DONE__';"
        } else if lower.contains("redis") {
            return "ECHO __SNEEK_DONE__"
        } else if lower.contains("cqlsh") {
            return "SELECT (text)'__SNEEK_DONE__' FROM system.local;"
        } else if lower.contains("mongosh") {
            return #"print("__SNEEK_DONE__")"#
        }
        return "echo __SNEEK_DONE__"
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Errors

public enum SessionError: Error, Equatable {
    case sessionNotFound(String)
    case blockedByReadonly(pattern: String, input: String)
    case processExited(code: Int32, stderr: String)
    case setupCommandFailed(command: String, output: String)
}
