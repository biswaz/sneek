import Foundation
@testable import SneekLib

private func baseCommand() -> CommandConfig {
    CommandConfig(
        name: "pg-test",
        description: "test",
        mode: .session,
        readonly: true,
        command: "psql {{host}}",
        secrets: ["password": .keychain(key: "pg-test")],
        variables: ["host": "localhost"],
        setupCommands: ["SET default_transaction_read_only = on;"],
        blockedPatterns: ["DROP", "DELETE"],
        sentinel: #"\echo __SNEEK_DONE__"#
    )
}

func runDaemonTests() {
    print("\nDaemon:")

    test("sessionConfigChanged: identical configs do not trigger reap") {
        let a = baseCommand()
        let b = baseCommand()
        check(!Daemon.sessionConfigChanged(a, b), "identical configs should be equal")
    }

    test("sessionConfigChanged: cosmetic-only changes do not trigger reap") {
        var a = baseCommand()
        var b = baseCommand()
        b.description = "different description"
        b.tags = ["new", "tags"]
        b.mcp = MCPConfig(enabled: true, toolName: "x", toolDescription: "y")
        b.readonly = false  // readonly alone — blocked patterns gate is per-call
        a.readonly = true
        check(!Daemon.sessionConfigChanged(a, b),
              "description/tags/mcp/readonly alone should not reap a live session")
    }

    test("sessionConfigChanged: setup_commands change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.setupCommands = nil
        check(Daemon.sessionConfigChanged(a, b),
              "clearing setup_commands must reap (this is the pg-dev bug)")
    }

    test("sessionConfigChanged: command template change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.command = "psql --csv {{host}}"
        check(Daemon.sessionConfigChanged(a, b), "command template change must reap")
    }

    test("sessionConfigChanged: secret change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.secrets = ["password": .keychain(key: "rotated-key")]
        check(Daemon.sessionConfigChanged(a, b), "rotated password must reap")
    }

    test("sessionConfigChanged: variable change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.variables = ["host": "different-host"]
        check(Daemon.sessionConfigChanged(a, b), "variable change must reap")
    }

    test("sessionConfigChanged: sentinel change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.sentinel = "echo __SNEEK_DONE__"
        check(Daemon.sessionConfigChanged(a, b), "sentinel change must reap")
    }

    test("sessionConfigChanged: tunnel change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.tunnel = TunnelConfig(host: "bastion.example.com", user: "deploy",
                                localPort: 15432, remoteHost: "db.internal", remotePort: 5432)
        check(Daemon.sessionConfigChanged(a, b), "adding tunnel must reap")
    }

    test("sessionConfigChanged: mode change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.mode = .oneshot
        check(Daemon.sessionConfigChanged(a, b), "mode change must reap")
    }

    test("tunnel down reaps the session bound to the dead forward") {
        let sem = DispatchSemaphore(value: 0)
        let box = ErrBox()
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sneek-daemon-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: tempDir) }

                var cmd = CommandConfig(
                    name: "t1", description: "test", mode: .session,
                    command: "bash", sentinel: "echo __SNEEK_DONE__"
                )
                cmd.tunnel = TunnelConfig(host: "bastion.example.com", user: "deploy",
                                          localPort: 25599, remoteHost: "db.internal", remotePort: 5432)
                let store = try ConfigStore(baseDir: tempDir)
                try store.save(cmd)

                let sessionMgr = SessionManager()
                let tunnelMgr = SSHTunnelManager()

                _ = try await sessionMgr.send(input: "echo hi", to: "t1", config: cmd, resolvedCommand: "bash")
                let before = await sessionMgr.activeSessions()
                check(before.contains("t1"), "session should be live before tunnel down")

                let resp = await Daemon.tunnelOp(
                    name: "t1", operation: "down",
                    configStore: store, sessionManager: sessionMgr, tunnelManager: tunnelMgr
                )
                check(resp.success, "tunnel down should succeed")
                let after = await sessionMgr.activeSessions()
                check(!after.contains("t1"), "session must be reaped when its tunnel is torn down")
            } catch {
                box.error = error
            }
            sem.signal()
        }
        sem.wait()
        if let e = box.error { throw e }
    }
}

private final class ErrBox: @unchecked Sendable {
    var error: (any Error)?
}
