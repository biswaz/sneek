import Foundation

public enum MCPError: Error {
    case invalidJSON
    case unknownMethod(String)
    case unknownTool(String)
    case missingParams
}

public final class MCPServer: @unchecked Sendable {
    private let configStore: ConfigStore
    private let sessionManager: SessionManager
    private let tunnelManager: SSHTunnelManager
    private let tagFilter: Set<String>?
    private let commandFilter: Set<String>?

    public init(
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager,
        tags: [String]? = nil,
        commands: [String]? = nil
    ) {
        self.configStore = configStore
        self.sessionManager = sessionManager
        self.tunnelManager = tunnelManager
        self.tagFilter = tags.map { Set($0) }
        self.commandFilter = commands.map { Set($0) }
    }

    // MARK: - Main Loop

    public func run() async throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let response = await handleMessage(line)
            if let response {
                writeResponse(response)
            }
        }
    }

    // MARK: - Dispatch

    func handleMessage(_ raw: String) async -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            // If there's an id, send a parse error; otherwise drop it
            return nil
        }

        let id = json["id"]  // may be nil for notifications

        switch method {
        case "initialize":
            return makeResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "sneek", "version": "0.1.0"],
            ])

        case "notifications/initialized":
            // No-op notification, no response
            return nil

        case "tools/list":
            let tools = buildToolList()
            return makeResult(id: id, result: ["tools": tools])

        case "tools/call":
            return await handleToolCall(id: id, params: json["params"] as? [String: Any])

        default:
            return makeError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool List

    func buildToolList() -> [[String: Any]] {
        var tools: [[String: Any]] = []

        for (_, cmd) in configStore.commands {
            guard let mcp = cmd.mcp, mcp.enabled else { continue }

            // Apply filters
            if let tagFilter {
                let cmdTags = Set(cmd.tags ?? [])
                if tagFilter.isDisjoint(with: cmdTags) { continue }
            }
            if let commandFilter, !commandFilter.contains(cmd.name) { continue }

            var description = mcp.toolDescription
            if cmd.readonly == true {
                description += " [read-only]"
            }

            let tool: [String: Any] = [
                "name": "sneek_\(mcp.toolName)",
                "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "The input to send to the command",
                        ] as [String: Any],
                    ] as [String: Any],
                    "required": ["input"],
                ] as [String: Any],
            ]
            tools.append(tool)
        }

        return tools
    }

    // MARK: - Tool Call

    private func handleToolCall(id: Any?, params: [String: Any]?) async -> [String: Any] {
        guard let params,
              let toolName = params["name"] as? String else {
            return makeError(id: id, code: -32602, message: "Missing tool name")
        }

        let arguments = params["arguments"] as? [String: Any]
        let input = arguments?["input"] as? String ?? ""

        // Find matching command
        guard let cmd = findCommand(toolName: toolName) else {
            return makeError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }

        do {
            // Resolve secrets and render command template
            let resolver = SecretResolver(
                secrets: cmd.secrets ?? [:],
                variables: cmd.variables ?? [:]
            )
            let resolved = try await resolver.resolveAll()
            let renderedCommand = try TemplateEngine.render(cmd.command, variables: resolved)

            // Ensure tunnel is up if configured
            if let tunnel = cmd.tunnel {
                try await tunnelManager.ensureUp(cmd.name, tunnel: tunnel)
            }

            // Execute
            let output: String
            switch cmd.mode {
            case .session:
                output = try await sessionManager.send(
                    input: input, to: cmd.name, config: cmd, resolvedCommand: renderedCommand
                )
            case .oneshot:
                output = try await sessionManager.runOneshot(
                    command: renderedCommand, input: input.isEmpty ? nil : input
                )
            }

            return makeResult(id: id, result: [
                "content": [["type": "text", "text": output]],
            ])
        } catch {
            return makeResult(id: id, result: [
                "content": [["type": "text", "text": "Error: \(error)"]],
                "isError": true,
            ])
        }
    }

    private func findCommand(toolName: String) -> CommandConfig? {
        for (_, cmd) in configStore.commands {
            guard let mcp = cmd.mcp, mcp.enabled else { continue }
            if "sneek_\(mcp.toolName)" == toolName {
                return cmd
            }
        }
        return nil
    }

    // MARK: - JSON-RPC Helpers

    private func makeResult(id: Any?, result: [String: Any]) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        return response
    }

    private func makeError(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any],
        ]
        if let id { response["id"] = id }
        return response
    }

    private func writeResponse(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              var line = String(data: data, encoding: .utf8) else { return }
        // Ensure single line (strip any embedded newlines from JSON)
        line = line.replacingOccurrences(of: "\n", with: "")
        print(line)
        fflush(stdout)
    }
}
