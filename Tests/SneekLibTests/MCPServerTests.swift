import Foundation
@testable import SneekLib

// Wrapper for non-Sendable dictionary results from MCP
private final class DictBox: @unchecked Sendable {
    var value: [String: Any]?
    init(_ value: [String: Any]? = nil) { self.value = value }
}

private func runBlockingDict(_ body: @Sendable @escaping () async -> [String: Any]?) -> [String: Any]? {
    let sem = DispatchSemaphore(value: 0)
    let box = DictBox()
    Task {
        let result = await body()
        box.value = result
        sem.signal()
    }
    sem.wait()
    return box.value
}

func runMCPServerTests() {
    print("\nMCPServer:")

    test("handleMessage parses initialize") {
        let server = try makeServer()
        let response = try runBlockingDict {
            let msg = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test"}}}"#
            return await server.handleMessage(msg)
        }
        check(response != nil, "response should not be nil")
        let result = response?["result"] as? [String: Any]
        check(result?["protocolVersion"] as? String == "2024-11-05", "protocol version")
        let serverInfo = result?["serverInfo"] as? [String: Any]
        check(serverInfo?["name"] as? String == "sneek", "server name")
    }

    test("handleMessage returns nil for notifications/initialized") {
        let server = try makeServer()
        let response = try runBlockingDict {
            let msg = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
            return await server.handleMessage(msg)
        }
        check(response == nil, "notification should return nil")
    }

    test("handleMessage returns error for unknown method") {
        let server = try makeServer()
        let response = try runBlockingDict {
            let msg = #"{"jsonrpc":"2.0","id":1,"method":"bogus/method"}"#
            return await server.handleMessage(msg)
        }
        check(response != nil, "response should not be nil")
        let error = response?["error"] as? [String: Any]
        check(error?["code"] as? Int == -32601, "error code")
    }

    test("buildToolList returns MCP-enabled commands") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)

        let cmd1 = CommandConfig(
            name: "pg-prod",
            description: "Production Postgres",
            mode: .session,
            readonly: true,
            command: "psql",
            mcp: MCPConfig(enabled: true, toolName: "pg_prod", toolDescription: "Query production database")
        )
        try store.save(cmd1)

        let cmd2 = CommandConfig(
            name: "redis-dev",
            description: "Dev Redis",
            mode: .session,
            command: "redis-cli",
            mcp: MCPConfig(enabled: false, toolName: "redis_dev", toolDescription: "Query dev Redis")
        )
        try store.save(cmd2)

        let cmd3 = CommandConfig(
            name: "local-echo",
            description: "Just echo",
            mode: .oneshot,
            command: "echo"
        )
        try store.save(cmd3)

        let server = MCPServer(
            configStore: store,
            sessionManager: SessionManager(),
            tunnelManager: SSHTunnelManager()
        )

        let tools = server.buildToolList()
        check(tools.count == 1, "only 1 MCP-enabled tool, got \(tools.count)")

        let tool = tools[0]
        check(tool["name"] as? String == "sneek_pg_prod", "tool name")

        let desc = tool["description"] as? String ?? ""
        check(desc.contains("[read-only]"), "read-only appended")
        check(desc.contains("Query production database"), "description base")
    }

    test("buildToolList respects tag filter") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)

        let cmd1 = CommandConfig(
            name: "db-prod",
            description: "Prod DB",
            tags: ["prod"],
            mode: .session,
            command: "psql",
            mcp: MCPConfig(enabled: true, toolName: "db_prod", toolDescription: "Prod DB")
        )
        try store.save(cmd1)

        let cmd2 = CommandConfig(
            name: "db-dev",
            description: "Dev DB",
            tags: ["dev"],
            mode: .session,
            command: "psql",
            mcp: MCPConfig(enabled: true, toolName: "db_dev", toolDescription: "Dev DB")
        )
        try store.save(cmd2)

        let server = MCPServer(
            configStore: store,
            sessionManager: SessionManager(),
            tunnelManager: SSHTunnelManager(),
            tags: ["prod"]
        )

        let tools = server.buildToolList()
        check(tools.count == 1, "only prod tool, got \(tools.count)")
        check(tools[0]["name"] as? String == "sneek_db_prod", "filtered to prod")
    }

    test("buildToolList respects command filter") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)

        let cmd1 = CommandConfig(
            name: "alpha",
            description: "Alpha",
            mode: .oneshot,
            command: "echo alpha",
            mcp: MCPConfig(enabled: true, toolName: "alpha", toolDescription: "Alpha cmd")
        )
        try store.save(cmd1)

        let cmd2 = CommandConfig(
            name: "beta",
            description: "Beta",
            mode: .oneshot,
            command: "echo beta",
            mcp: MCPConfig(enabled: true, toolName: "beta", toolDescription: "Beta cmd")
        )
        try store.save(cmd2)

        let server = MCPServer(
            configStore: store,
            sessionManager: SessionManager(),
            tunnelManager: SSHTunnelManager(),
            commands: ["beta"]
        )

        let tools = server.buildToolList()
        check(tools.count == 1, "only beta, got \(tools.count)")
        check(tools[0]["name"] as? String == "sneek_beta", "filtered to beta")
    }

    test("tools/list via handleMessage") {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sneek-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ConfigStore(baseDir: tempDir)
        let cmd = CommandConfig(
            name: "echo-cmd",
            description: "Echo",
            mode: .oneshot,
            command: "echo",
            mcp: MCPConfig(enabled: true, toolName: "echo_cmd", toolDescription: "Echo things")
        )
        try store.save(cmd)

        let server = MCPServer(
            configStore: store,
            sessionManager: SessionManager(),
            tunnelManager: SSHTunnelManager()
        )

        let response = try runBlockingDict {
            let msg = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
            return await server.handleMessage(msg)
        }

        check(response != nil, "response should not be nil")
        check(response?["id"] as? Int == 2, "id preserved")
        let result = response?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        check(tools?.count == 1, "one tool")
        check(tools?[0]["name"] as? String == "sneek_echo_cmd", "tool name via handleMessage")
    }
}

private func makeServer() throws -> MCPServer {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sneek-mcp-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let store = try ConfigStore(baseDir: tempDir)
    return MCPServer(
        configStore: store,
        sessionManager: SessionManager(),
        tunnelManager: SSHTunnelManager()
    )
}
