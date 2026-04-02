import Foundation

// MARK: - Secret Provider Protocol

public protocol SecretProvider: Sendable {
    func resolve(_ key: String) async throws -> String
}

// MARK: - Errors

public enum SecretResolutionError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case envNotFound(variable: String)

    public var description: String {
        switch self {
        case .commandFailed(let cmd, let code, let stderr):
            return "\(cmd) exited with code \(code): \(stderr)"
        case .envNotFound(let variable):
            return "Environment variable not found: \(variable)"
        }
    }
}

// MARK: - Shell Provider Helper

private func runProcess(_ executable: String, _ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let cmd = ([executable] + arguments).joined(separator: " ")
        throw SecretResolutionError.commandFailed(
            command: cmd, exitCode: process.terminationStatus, stderr: stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Path Resolution

private func findExecutable(_ name: String, fallback: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    p.arguments = [name]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    if p.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty { return path }
    }
    return fallback
}

// MARK: - Provider Implementations

public struct KeychainProvider: SecretProvider {
    public init() {}

    public func resolve(_ key: String) async throws -> String {
        // Try generic password first (security add-generic-password / Passwords app)
        // Fall back to internet password (security add-internet-password)
        do {
            return try await runProcess("/usr/bin/security", ["find-generic-password", "-s", key, "-w"])
        } catch {
            return try await runProcess("/usr/bin/security", ["find-internet-password", "-s", key, "-w"])
        }
    }
}

public struct OnePasswordProvider: SecretProvider {
    public init() {}

    public func resolve(_ ref: String) async throws -> String {
        try await runProcess(findExecutable("op", fallback: "/usr/local/bin/op"), ["read", ref])
    }
}

public struct BitwardenProvider: SecretProvider {
    public init() {}

    public func resolve(_ item: String) async throws -> String {
        try await runProcess(findExecutable("bw", fallback: "/usr/local/bin/bw"), ["get", "password", item])
    }
}

public struct EnvProvider: SecretProvider {
    public init() {}

    public func resolve(_ variable: String) async throws -> String {
        guard let value = ProcessInfo.processInfo.environment[variable] else {
            throw SecretResolutionError.envNotFound(variable: variable)
        }
        return value
    }
}

// MARK: - Secret Resolver

public final class SecretResolver: @unchecked Sendable {
    private let secrets: [String: SecretRef]
    private let variables: [String: String]
    private let keychainProvider: SecretProvider
    private let onePasswordProvider: SecretProvider
    private let bitwardenProvider: SecretProvider
    private let envProvider: SecretProvider

    public init(
        secrets: [String: SecretRef],
        variables: [String: String] = [:],
        keychainProvider: SecretProvider = KeychainProvider(),
        onePasswordProvider: SecretProvider = OnePasswordProvider(),
        bitwardenProvider: SecretProvider = BitwardenProvider(),
        envProvider: SecretProvider = EnvProvider()
    ) {
        self.secrets = secrets
        self.variables = variables
        self.keychainProvider = keychainProvider
        self.onePasswordProvider = onePasswordProvider
        self.bitwardenProvider = bitwardenProvider
        self.envProvider = envProvider
    }

    public func resolveAll() async throws -> [String: String] {
        var result = variables

        for (name, ref) in secrets {
            let provider: String
            let value: String
            switch ref {
            case .keychain(let key):
                provider = "keychain"
                value = try await keychainProvider.resolve(key)
            case .onePassword(let opRef):
                provider = "1password"
                value = try await onePasswordProvider.resolve(opRef)
            case .bitwarden(let item):
                provider = "bitwarden"
                value = try await bitwardenProvider.resolve(item)
            case .env(let variable):
                provider = "env"
                value = try await envProvider.resolve(variable)
            }
            SneekLogger.debug("secret '\(name)': resolved via \(provider)")
            result[name] = value
        }

        return result
    }
}
