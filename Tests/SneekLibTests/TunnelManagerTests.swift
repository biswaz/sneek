import Foundation
@testable import SneekLib

// MARK: - Mock Tunnel Manager

actor MockTunnelManager: TunnelManagerProtocol {
    private var tunnels: [String: TunnelStatus] = [:]

    func ensureUp(_ name: String, tunnel: TunnelConfig) async throws {
        tunnels[name] = .up
    }

    func tearDown(_ name: String) async throws {
        tunnels.removeValue(forKey: name)
    }

    func status(_ name: String) async -> TunnelStatus {
        tunnels[name] ?? .down
    }

    func tearDownAll() async {
        tunnels.removeAll()
    }
}

// MARK: - Async test helper

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func runBlocking(_ body: @Sendable @escaping () async throws -> Void) throws {
    let sem = DispatchSemaphore(value: 0)
    let errorBox = Box<(any Error)?>(nil)
    Task {
        do {
            try await body()
        } catch {
            errorBox.value = error
        }
        sem.signal()
    }
    sem.wait()
    if let error = errorBox.value { throw error }
}

// MARK: - Tests

func runTunnelManagerTests() {
    print("\nTunnelManager:")

    test("Status returns .down for unknown tunnel") {
        try runBlocking {
            let manager = SSHTunnelManager()
            let s = await manager.status("nonexistent")
            check(s == .down, "expected .down for unknown tunnel, got \(s)")
        }
    }

    test("Mock ensureUp sets status to .up") {
        try runBlocking {
            let mock = MockTunnelManager()
            let config = TunnelConfig(
                host: "bastion.example.com",
                user: "deploy",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
            try await mock.ensureUp("test-tunnel", tunnel: config)
            let s = await mock.status("test-tunnel")
            check(s == .up, "expected .up after ensureUp, got \(s)")
        }
    }

    test("Mock tearDown removes tunnel") {
        try runBlocking {
            let mock = MockTunnelManager()
            let config = TunnelConfig(
                host: "bastion.example.com",
                user: "deploy",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
            try await mock.ensureUp("t1", tunnel: config)
            try await mock.tearDown("t1")
            let s = await mock.status("t1")
            check(s == .down, "expected .down after tearDown, got \(s)")
        }
    }

    test("Mock tearDownAll clears everything") {
        try runBlocking {
            let mock = MockTunnelManager()
            let config = TunnelConfig(
                host: "bastion.example.com",
                user: "deploy",
                localPort: 15432,
                remoteHost: "db.internal",
                remotePort: 5432
            )
            try await mock.ensureUp("a", tunnel: config)
            try await mock.ensureUp("b", tunnel: config)
            await mock.tearDownAll()
            let sa = await mock.status("a")
            let sb = await mock.status("b")
            check(sa == .down, "expected .down for 'a' after tearDownAll")
            check(sb == .down, "expected .down for 'b' after tearDownAll")
        }
    }

    test("Mock tearDown on unknown tunnel is no-op") {
        try runBlocking {
            let mock = MockTunnelManager()
            try await mock.tearDown("ghost")
            let s = await mock.status("ghost")
            check(s == .down, "expected .down for never-added tunnel")
        }
    }
}
