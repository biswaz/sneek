import Foundation
@testable import SneekLib

private func runBlocking<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do {
            let value = try await body()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        sem.signal()
    }
    sem.wait()
    return try result!.get()
}

func runSessionManagerTests() {
    print("\nSessionManager:")

    test("Oneshot runs command and returns output") {
        let result: String = try runBlocking {
            let manager = SessionManager()
            return try await manager.runOneshot(command: "echo hello", input: nil)
        }
        check(result == "hello", "got: \(result)")
    }

    test("Oneshot with input") {
        let result: String = try runBlocking {
            let manager = SessionManager()
            return try await manager.runOneshot(command: "echo", input: "world")
        }
        check(result == "world", "got: \(result)")
    }

    test("Multi-line sentinel output leaks nothing (cqlsh-style)") {
        // cqlsh's sentinel SELECT prints a result table where the marker appears
        // twice: in the column header and in the value row. None of that block
        // may leak into the returned output.
        let result: String = try runBlocking {
            let manager = SessionManager()
            defer { Task { await manager.reapAll() } }
            let config = CommandConfig(
                name: "cql-style",
                description: "test",
                mode: .session,
                command: "bash",
                sentinel: #"printf ' (text)__SNEEK_DONE__\n------\n __SNEEK_DONE__\n\n(1 rows)\n'"#
            )
            return try await manager.send(
                input: "echo real-output",
                to: "cql-style", config: config, resolvedCommand: "bash"
            )
        }
        check(result == "real-output", "sentinel block leaked into output: \(result.debugDescription)")
    }

    test("Blocked pattern rejects write commands") {
        var caught = false
        do {
            let _: String = try runBlocking {
                let manager = SessionManager()
                let config = CommandConfig(
                    name: "test",
                    description: "test",
                    mode: .session,
                    readonly: true,
                    command: "cat",
                    blockedPatterns: ["DROP", "DELETE"]
                )
                return try await manager.send(input: "DROP TABLE users", to: "test", config: config, resolvedCommand: "cat")
            }
        } catch let error as SessionError {
            if case .blockedByReadonly(let pattern, _) = error {
                caught = true
                check(pattern == "DROP", "pattern: \(pattern)")
            }
        }
        check(caught, "should have thrown blockedByReadonly")
    }

    test("Blocked patterns are case-insensitive") {
        var caught = false
        do {
            let _: String = try runBlocking {
                let manager = SessionManager()
                let config = CommandConfig(
                    name: "test2",
                    description: "test",
                    mode: .session,
                    readonly: true,
                    command: "cat",
                    blockedPatterns: ["DELETE"]
                )
                return try await manager.send(input: "delete from users", to: "test2", config: config, resolvedCommand: "cat")
            }
        } catch is SessionError {
            caught = true
        }
        check(caught, "case-insensitive block")
    }

    test("Session preserves multibyte output split across pipe chunks") {
        // >64KB of 3-byte runes guarantees pipe reads that split characters
        // mid-rune; dropped chunks show up as missing lines.
        let result: String = try runBlocking {
            let manager = SessionManager()
            let config = CommandConfig(
                name: "utf8-chunks",
                description: "test",
                mode: .session,
                command: "bash"
            )
            let input = "for i in $(seq 1 20000); do echo '日本語テキストです'; done"
            let out = try await manager.send(input: input, to: "utf8-chunks", config: config, resolvedCommand: "bash")
            await manager.reapAll()
            return out
        }
        let count = result.components(separatedBy: "\n").filter { $0.contains("日本語テキストです") }.count
        check(count == 20000, "expected 20000 multibyte lines, got \(count)")
    }

    test("Active sessions starts empty") {
        let names: [String] = try runBlocking {
            let manager = SessionManager()
            return await manager.activeSessions()
        }
        check(names.isEmpty, "starts empty")
    }
}
