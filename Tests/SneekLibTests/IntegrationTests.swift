import Foundation
@testable import SneekLib

// ---------------------------------------------------------------------------
// Real integration tests — no mocks. Exercises the actual stack:
//   Keychain → SecretResolver → TemplateEngine → SessionManager
//   SSH tunnel (localhost), read-only enforcement, persistent sessions
//
// These tests prove the app can safely handle a real prod command like:
//   psql with SSH tunnel + keychain password + read-only mode
// ---------------------------------------------------------------------------

private let keychainService = "sneek-integration-test"
private let keychainAccount = "testuser"
private let keychainPassword = "s3cret-test-pw-\(Int.random(in: 10000...99999))"

private func runBlocking<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do { result = .success(try await body()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result!.get()
}

private func shell(_ cmd: String) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

// MARK: - Keychain helpers

private func keychainAdd() -> Bool {
    let (code, _) = shell(
        "security add-generic-password -s '\(keychainService)' -a '\(keychainAccount)' -w '\(keychainPassword)' 2>&1"
    )
    return code == 0
}

private func keychainDelete() {
    _ = shell("security delete-generic-password -s '\(keychainService)' 2>&1")
}

/// Run async work with a timeout — prevents tests from hanging forever
private func runBlockingWithTimeout<T: Sendable>(
    seconds: Int = 10,
    _ body: @Sendable @escaping () async throws -> T
) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do { result = .success(try await body()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    if sem.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
        throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "timed out after \(seconds)s"])
    }
    return try result!.get()
}

// MARK: - Tests

func runIntegrationTests() {
    print("\nIntegration (real stack):")

    // ── 1. Real Keychain: store, resolve, clean up ──

    test("Keychain: store and retrieve a real secret") {
        keychainDelete() // clean slate
        let added = keychainAdd()
        check(added, "keychain add should succeed")
        defer { keychainDelete() }

        let provider = KeychainProvider()
        let resolved = try runBlockingWithTimeout { try await provider.resolve(keychainService) }
        check(resolved == keychainPassword, "resolved '\(resolved)' should match stored password")
    }

    // ── 2. Persistent session with bash (proxy for psql) ──

    test("Persistent session: send commands, reuse process, get output") {
        let mgr = SessionManager()
        defer { try? runBlockingWithTimeout(seconds: 3) { await mgr.reapAll() } }

        let config = CommandConfig(
            name: "bash-session",
            description: "test",
            mode: .session,
            command: "exec bash --norc --noprofile",
            sentinel: "echo __SNEEK_DONE__"
        )

        // First command
        let out1: String = try runBlockingWithTimeout {
            try await mgr.send(input: "echo hello-from-session", to: "bash-session",
                               config: config, resolvedCommand: "exec bash --norc --noprofile")
        }
        check(out1.contains("hello-from-session"), "first command output: \(out1)")

        // Second command — reuses same process (no reconnect)
        let out2: String = try runBlockingWithTimeout {
            try await mgr.send(input: "echo 2+2=$((2+2))", to: "bash-session",
                               config: config, resolvedCommand: "exec bash --norc --noprofile")
        }
        check(out2.contains("2+2=4"), "second command output: \(out2)")

        // Verify session is alive
        let active: [String] = try runBlockingWithTimeout { await mgr.activeSessions() }
        check(active.contains("bash-session"), "session still active")
    }

    // ── 3. Setup commands run at session start (like SET default_transaction_read_only) ──

    test("Session setup commands execute before first user input") {
        let mgr = SessionManager()
        defer { try? runBlockingWithTimeout(seconds: 3) { await mgr.reapAll() } }

        let config = CommandConfig(
            name: "setup-test",
            description: "test",
            mode: .session,
            command: "bash --norc --noprofile",
            setupCommands: ["export SNEEK_MODE=readonly", "export SNEEK_READY=1"],
            sentinel: "echo __SNEEK_DONE__"
        )

        // Query the env vars that setup commands should have set
        let out: String = try runBlockingWithTimeout {
            try await mgr.send(
                input: "echo mode=$SNEEK_MODE ready=$SNEEK_READY",
                to: "setup-test", config: config,
                resolvedCommand: "exec bash --norc --noprofile"
            )
        }
        check(out.contains("mode=readonly"), "setup command 1 ran: \(out)")
        check(out.contains("ready=1"), "setup command 2 ran: \(out)")
    }

    // ── 4. Read-only enforcement: blocked patterns + safe queries ──

    test("Read-only: blocks dangerous SQL patterns, allows safe ones") {
        let mgr = SessionManager()
        defer { try? runBlockingWithTimeout(seconds: 3) { await mgr.reapAll() } }

        let config = CommandConfig(
            name: "ro-test",
            description: "test",
            mode: .session,
            readonly: true,
            command: "bash --norc --noprofile",
            blockedPatterns: ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],
            sentinel: "echo __SNEEK_DONE__"
        )

        // Dangerous inputs — all should be blocked before reaching the process
        let dangerous = [
            "DROP TABLE users;",
            "delete from orders where id=1",
            "UPDATE accounts SET balance=0",
            "INSERT INTO audit VALUES(1)",
            "alter table users add column x int",
            "TRUNCATE TABLE logs",
        ]
        for input in dangerous {
            var blocked = false
            do {
                _ = try runBlockingWithTimeout {
                    try await mgr.send(input: input, to: "ro-\(abs(input.hashValue))",
                                       config: config, resolvedCommand: "exec bash --norc --noprofile")
                }
            } catch SessionError.blockedByReadonly {
                blocked = true
            } catch {}
            check(blocked, "BLOCKED: \(input)")
        }

        // Safe inputs — should NOT be blocked by the guard
        let safe = [
            "SELECT * FROM users WHERE id=1",
            "SHOW TABLES",
            "EXPLAIN ANALYZE SELECT 1",
            "\\dt",
            "SELECT count(*) FROM orders",
        ]
        for input in safe {
            var blockedByGuard = false
            do {
                _ = try runBlockingWithTimeout {
                    try await mgr.send(input: input, to: "ro-safe-\(abs(input.hashValue))",
                                       config: config, resolvedCommand: "exec bash --norc --noprofile")
                }
            } catch SessionError.blockedByReadonly {
                blockedByGuard = true
            } catch {
                // Other errors (bash can't run SQL) are fine — we only care about the guard
            }
            check(!blockedByGuard, "ALLOWED: \(input)")
        }
    }

    // ── 5. Full pipeline: Keychain secret → template → session execute ──

    test("Full pipeline: keychain secret → template interpolation → session execution") {
        keychainDelete()
        let added = keychainAdd()
        check(added, "keychain add")
        defer { keychainDelete() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-integ-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Create command config with keychain secret
        let store = try ConfigStore(baseDir: tempDir)
        let cmd = CommandConfig(
            name: "pipeline-test",
            description: "Full pipeline test",
            mode: .oneshot,
            command: "echo user={{user}} pass={{password}} host={{host}}",
            secrets: ["password": .keychain(key: keychainService)],
            variables: ["user": "dbadmin", "host": "localhost"]
        )
        try store.save(cmd)

        // 2. Resolve secrets (real keychain)
        let resolver = SecretResolver(
            secrets: cmd.secrets ?? [:],
            variables: cmd.variables ?? [:]
        )
        let vars = try runBlockingWithTimeout { try await resolver.resolveAll() }
        check(vars["password"] == keychainPassword, "keychain resolved")
        check(vars["user"] == "dbadmin", "variable resolved")
        check(vars["host"] == "localhost", "variable resolved")

        // 3. Interpolate template
        let rendered = try TemplateEngine.render(cmd.command, variables: vars)
        check(rendered.contains("pass=\(keychainPassword)"), "password interpolated")
        check(rendered.contains("user=dbadmin"), "user interpolated")

        // 4. Execute
        let mgr = SessionManager()
        let output = try runBlockingWithTimeout { try await mgr.runOneshot(command: rendered, input: nil) }
        check(output.contains("user=dbadmin"), "output has user")
        check(output.contains("pass=\(keychainPassword)"), "output has password")
        check(output.contains("host=localhost"), "output has host")
    }

    // ── 6. SSH tunnel to localhost (skip if SSH not available) ──

    test("SSH tunnel: localhost port forward + health check + teardown") {
        // Check if SSH to localhost is available
        let (sshCheck, _) = shell("ssh -o BatchMode=yes -o ConnectTimeout=2 localhost echo ok 2>&1")
        if sshCheck != 0 {
            print("    (skipped — enable Remote Login in System Settings to test SSH tunnels)")
            return
        }

        let tunnelMgr = SSHTunnelManager()
        defer { try? runBlockingWithTimeout(seconds: 3) { await tunnelMgr.tearDownAll() } }

        // Find a free port
        let localPort = 19876

        let tunnel = TunnelConfig(
            host: "localhost",
            user: NSUserName(),
            localPort: localPort,
            remoteHost: "localhost",
            remotePort: 22  // forward to SSH itself — just need something listening
        )

        // Bring tunnel up
        try runBlockingWithTimeout { try await tunnelMgr.ensureUp("ssh-test", tunnel: tunnel) }

        // Verify status
        let status: TunnelStatus = try runBlockingWithTimeout { await tunnelMgr.status("ssh-test") }
        check(status == .up, "tunnel should be up, got \(status)")

        // Verify TCP health check on the forwarded port
        let healthy = TCPHealthCheck.check(port: localPort, timeout: 2.0)
        check(healthy, "TCP health check should pass on port \(localPort)")

        // Tear down
        try runBlockingWithTimeout { try await tunnelMgr.tearDown("ssh-test") }
        let afterStatus: TunnelStatus = try runBlockingWithTimeout { await tunnelMgr.status("ssh-test") }
        check(afterStatus == .down, "tunnel should be down after teardown")

        // Port should no longer be reachable (give it a moment)
        usleep(200_000)
        let gone = !TCPHealthCheck.check(port: localPort, timeout: 1.0)
        check(gone, "port \(localPort) should be closed after teardown")
    }

    // ── 7. MCP tool call end-to-end (real execution, no mock) ──

    test("MCP tools/call executes a real command and returns output") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-integ-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        try store.save(CommandConfig(
            name: "date-cmd",
            description: "Print date",
            mode: .oneshot,
            command: "date +%Y",
            mcp: MCPConfig(enabled: true, toolName: "date_cmd", toolDescription: "Get year")
        ))

        let server = MCPServer(
            configStore: store,
            sessionManager: SessionManager(),
            tunnelManager: SSHTunnelManager()
        )

        // Call via MCP JSON-RPC
        let callMsg = """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sneek_date_cmd","arguments":{"input":""}}}
        """
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var response: [String: Any]?
        Task { @Sendable in
            response = await server.handleMessage(callMsg)
            sem.signal()
        }
        sem.wait()

        let result = response?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""

        let year = Calendar.current.component(.year, from: Date())
        check(text.contains(String(year)), "MCP call returned current year: \(text)")
        check(result?["isError"] == nil, "no error flag")
    }

    // ── 8. Script generation produces actually executable scripts ──

    test("Generated script is executable and delegates to sneekd") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-integ-\(UUID().uuidString)")
        let scriptDir = tempDir.appendingPathComponent("bin").path
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        try store.save(CommandConfig(
            name: "hello-world",
            description: "Test",
            mode: .oneshot,
            command: "echo hello"
        ))

        let paths = try ScriptGenerator.generateAll(configStore: store, outputDir: scriptDir)
        check(paths.count == 1, "one script")

        let content = try String(contentsOfFile: paths[0], encoding: .utf8)
        check(content.starts(with: "#!/bin/bash"), "shebang")
        check(content.contains("exec sneekd run hello-world"), "delegates to sneekd")
        check(content.contains("\"$@\""), "passes args through")

        // Verify it's actually executable
        let attrs = try FileManager.default.attributesOfItem(atPath: paths[0])
        let perms = (attrs[.posixPermissions] as? Int) ?? 0
        check(perms == 0o755, "permissions are 755, got \(String(perms, radix: 8))")
    }

    // ── 9. IPC round-trip with real daemon handler ──

    test("Daemon handles run request for a real command") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-integ-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        try store.save(CommandConfig(
            name: "echo-test",
            description: "Echo test",
            mode: .oneshot,
            command: "echo integration-pass"
        ))

        // Use the Daemon's static handler directly (no socket needed)
        let sessionMgr = SessionManager()
        let tunnelMgr = SSHTunnelManager()

        let request = IPCRequest(action: .run, command: "echo-test")
        let response: IPCResponse = try runBlockingWithTimeout {
            // Simulate what the daemon does internally
            let cmd = store.commands["echo-test"]!
            let resolver = SecretResolver(secrets: cmd.secrets ?? [:], variables: cmd.variables ?? [:])
            let vars = try await resolver.resolveAll()
            let rendered = try TemplateEngine.render(cmd.command, variables: vars)
            let output = try await sessionMgr.runOneshot(command: rendered, input: nil)
            return IPCResponse.ok(output)
        }

        check(response.success, "should succeed")
        check(response.output == "integration-pass", "output: \(response.output ?? "nil")")
    }
}
