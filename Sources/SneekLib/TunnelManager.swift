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
    var reconnectDelay: TimeInterval = 1.0
}

// MARK: - Errors

public enum TunnelError: Error {
    case sshSpawnFailed(String)
    case healthCheckFailed(port: Int)
}

// MARK: - SSH Tunnel Manager

public actor SSHTunnelManager: TunnelManagerProtocol {
    private var tunnels: [String: TunnelState] = [:]
    private var monitorTask: Task<Void, Never>?

    public init() {}

    /// Kill stale SSH tunnel processes on a port — only kills ssh processes
    /// with our specific -L forward pattern, not arbitrary processes.
    private func killStaleTunnel(on port: Int, tunnel: TunnelConfig) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Match: ssh processes with our exact local forward pattern
        p.arguments = ["-f", "ssh.*-L.*\(port):\(tunnel.remoteHost):\(tunnel.remotePort).*\(tunnel.host)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
        for pid in pids {
            SneekLogger.info("tunnel: killing stale ssh process \(pid) (port \(port) → \(tunnel.remoteHost):\(tunnel.remotePort))")
            kill(pid, SIGTERM)
        }
        if !pids.isEmpty {
            usleep(200_000)
        }
    }

    public func ensureUp(_ name: String, tunnel: TunnelConfig) async throws {
        // If already tracked and process is running, verify health
        if let existing = tunnels[name], existing.process.isRunning {
            if TCPHealthCheck.check(port: tunnel.localPort, timeout: 1.0) {
                return
            }
            SneekLogger.warn("tunnel/\(name): health check failed on port \(tunnel.localPort), respawning")
            existing.process.terminate()
            tunnels.removeValue(forKey: name)
        }

        // Kill stale SSH tunnel from a previous daemon run (matches our exact pattern only)
        if TCPHealthCheck.check(port: tunnel.localPort, timeout: 0.5) {
            killStaleTunnel(on: tunnel.localPort, tunnel: tunnel)
        }

        let process = try spawnSSH(tunnel: tunnel)

        if !(await waitForHealthy(name: name, process: process, port: tunnel.localPort)) {
            if process.isRunning { process.terminate() }
            throw TunnelError.healthCheckFailed(port: tunnel.localPort)
        }

        tunnels[name] = TunnelState(process: process, status: .up, config: tunnel)
        SneekLogger.info("tunnel/\(name): up on port \(tunnel.localPort)")
    }

    public func tearDown(_ name: String) async throws {
        guard let state = tunnels.removeValue(forKey: name) else { return }
        if state.process.isRunning {
            state.process.terminate()
        }
        SneekLogger.info("tunnel/\(name): torn down")
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

    // MARK: - Health Monitoring

    public func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard !Task.isCancelled else { break }
                await self?.checkAllTunnels()
            }
        }
        SneekLogger.info("tunnel monitor: started")
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        SneekLogger.info("tunnel monitor: stopped")
    }

    private func checkAllTunnels() async {
        for (name, state) in tunnels {
            let processAlive = state.process.isRunning
            let portHealthy = processAlive && TCPHealthCheck.check(port: state.config.localPort, timeout: 1.0)

            if portHealthy { continue }

            SneekLogger.warn("tunnel/\(name): unhealthy (process running: \(processAlive)), reconnecting")
            tunnels[name]?.status = .reconnecting

            // Tear down old process
            if processAlive {
                state.process.terminate()
            }

            // Exponential backoff reconnect
            let delay = state.reconnectDelay
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            do {
                let newProcess = try spawnSSH(tunnel: state.config)
                if await waitForHealthy(name: name, process: newProcess, port: state.config.localPort) {
                    tunnels[name] = TunnelState(process: newProcess, status: .up, config: state.config, reconnectDelay: 1.0)
                    SneekLogger.info("tunnel/\(name): reconnected successfully")
                } else {
                    if newProcess.isRunning { newProcess.terminate() }
                    let nextDelay = min(delay * 2, 30.0)
                    tunnels[name] = TunnelState(process: newProcess, status: .down, config: state.config, reconnectDelay: nextDelay)
                    SneekLogger.error("tunnel/\(name): reconnect failed, next retry in \(nextDelay)s")
                }
            } catch {
                let nextDelay = min(delay * 2, 30.0)
                tunnels[name] = TunnelState(process: state.process, status: .down, config: state.config, reconnectDelay: nextDelay)
                SneekLogger.error("tunnel/\(name): ssh spawn failed: \(error), next retry in \(nextDelay)s")
            }
        }
    }

    // MARK: - Private

    /// Poll up to `maxAttempts` × 0.5s for the local forward port to become reachable.
    /// SSH key exchange through a bastion can easily take 2–3s — a single short wait
    /// kills the ssh process before it has a chance to bind.
    private func waitForHealthy(name: String, process: Process, port: Int, maxAttempts: Int = 10) async -> Bool {
        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !process.isRunning {
                let stderr = sshStderr(process)
                SneekLogger.error("tunnel/\(name): ssh exited (\(process.terminationStatus)): \(stderr)")
                return false
            }
            if TCPHealthCheck.check(port: port, timeout: 1.0) {
                return true
            }
        }
        return false
    }

    private func spawnSSH(tunnel: TunnelConfig) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", "\(tunnel.localPort):\(tunnel.remoteHost):\(tunnel.remotePort)",
        ]
        if let key = tunnel.identityKey {
            let expanded = NSString(string: key).expandingTildeInPath
            args += ["-i", expanded]
        }
        args.append("\(tunnel.user)@\(tunnel.host)")

        process.arguments = args
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw TunnelError.sshSpawnFailed(error.localizedDescription)
        }

        return process
    }

    private func sshStderr(_ process: Process) -> String {
        guard let pipe = process.standardError as? Pipe else { return "(no stderr)" }
        let data = pipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(unreadable)"
    }
}
