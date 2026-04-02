import Foundation

// MARK: - Protocol

public protocol TunnelManagerProtocol: Sendable {
    func ensureUp(_ name: String, tunnel: TunnelConfig) async throws
    func tearDown(_ name: String) async throws
    func status(_ name: String) async -> TunnelStatus
    func tearDownAll() async
}

// MARK: - TCP Health Check

enum TCPHealthCheck {
    static func check(port: Int, timeout: TimeInterval = 2.0) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Set send timeout so connect doesn't block forever
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Tunnel State

struct TunnelState {
    var process: Process
    var status: TunnelStatus
    var config: TunnelConfig
}

// MARK: - Errors

public enum TunnelError: Error {
    case sshSpawnFailed(String)
    case healthCheckFailed(port: Int)
}

// MARK: - SSH Tunnel Manager

public actor SSHTunnelManager: TunnelManagerProtocol {
    private var tunnels: [String: TunnelState] = [:]

    public init() {}

    public func ensureUp(_ name: String, tunnel: TunnelConfig) async throws {
        // If already tracked and process is running, verify health
        if let existing = tunnels[name], existing.process.isRunning {
            if TCPHealthCheck.check(port: tunnel.localPort, timeout: 1.0) {
                return
            }
            // Process running but port unhealthy — tear down and respawn
            existing.process.terminate()
            tunnels.removeValue(forKey: name)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(tunnel.localPort):\(tunnel.remoteHost):\(tunnel.remotePort)",
        ]
        if let key = tunnel.identityKey {
            args += ["-i", key]
        }
        args.append("\(tunnel.user)@\(tunnel.host)")

        process.arguments = args

        do {
            try process.run()
        } catch {
            throw TunnelError.sshSpawnFailed(error.localizedDescription)
        }

        // Give ssh a moment to establish the forward, then health-check
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

        let healthy = TCPHealthCheck.check(port: tunnel.localPort)
        if !healthy {
            process.terminate()
            throw TunnelError.healthCheckFailed(port: tunnel.localPort)
        }

        tunnels[name] = TunnelState(process: process, status: .up, config: tunnel)
    }

    public func tearDown(_ name: String) async throws {
        guard let state = tunnels.removeValue(forKey: name) else { return }
        if state.process.isRunning {
            state.process.terminate()
        }
    }

    public func status(_ name: String) async -> TunnelStatus {
        guard let state = tunnels[name] else { return .down }
        if !state.process.isRunning { return .down }
        return state.status
    }

    public func tearDownAll() async {
        for (_, state) in tunnels {
            if state.process.isRunning {
                state.process.terminate()
            }
        }
        tunnels.removeAll()
    }
}
