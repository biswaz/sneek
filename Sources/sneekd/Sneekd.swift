import ArgumentParser
import Foundation
import SneekLib

@main
struct Sneekd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sneekd",
        abstract: "Sneek daemon — manage tunnels, secrets, and commands",
        subcommands: [
            Start.self,
            Stop.self,
            Status.self,
            Run.self,
            Tunnel.self,
            List.self,
            MCPServe.self,
            GenerateScripts.self,
            InstallMCP.self,
        ]
    )
}

// MARK: - Helpers

func defaultConfigDir() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".config/sneek")
}

func defaultSocketPath() -> String {
    defaultConfigDir().appendingPathComponent("sneekd.sock").path
}

// MARK: - Start

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the daemon")

    func run() async throws {
        let configStore = try ConfigStore(baseDir: defaultConfigDir())
        let daemon = Daemon(configStore: configStore)
        print("sneekd: starting daemon...")
        try await daemon.start()
    }
}

// MARK: - Stop

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the daemon")

    func run() throws {
        let client = IPCClient(socketPath: defaultSocketPath())
        let response = try client.send(IPCRequest(action: .shutdown))
        print(response.output ?? response.error ?? "stopped")
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon status")

    func run() throws {
        let client = IPCClient(socketPath: defaultSocketPath())
        let response = try client.send(IPCRequest(action: .status))
        if response.success {
            print(response.output ?? "ok")
        } else {
            print("error: \(response.error ?? "unknown")")
        }
    }
}

// MARK: - Run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command")
    @Argument(help: "Command name") var name: String
    @Argument(help: "Input to send") var input: String?

    func run() throws {
        let client = IPCClient(socketPath: defaultSocketPath())
        let response = try client.send(IPCRequest(action: .run, command: name, input: input))
        if response.success {
            if let output = response.output {
                print(output)
            }
        } else {
            fputs("error: \(response.error ?? "unknown")\n", stderr)
            throw ExitCode.failure
        }
    }
}

// MARK: - Tunnel

struct Tunnel: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage tunnels")
    @Argument(help: "Command name") var name: String
    @Argument(help: "Operation: up, down, status") var operation: String

    func run() throws {
        let client = IPCClient(socketPath: defaultSocketPath())
        let response = try client.send(IPCRequest(action: .tunnel, command: name, operation: operation))
        if response.success {
            print(response.output ?? "ok")
        } else {
            fputs("error: \(response.error ?? "unknown")\n", stderr)
            throw ExitCode.failure
        }
    }
}

// MARK: - List

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List all commands")

    func run() throws {
        let configStore = try ConfigStore(baseDir: defaultConfigDir())
        for (name, cmd) in configStore.commands.sorted(by: { $0.key < $1.key }) {
            var flags: [String] = []
            if cmd.tunnel != nil { flags.append("tunnel") }
            if cmd.mcp?.enabled == true { flags.append("mcp") }
            if cmd.readonly == true { flags.append("read-only") }
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            print("  \(name) — \(cmd.description)\(flagStr)")
        }
    }
}

// MARK: - MCP Serve

struct MCPServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-serve",
        abstract: "Run as MCP server (stdio)"
    )
    @Option(help: "Filter by tags (comma-separated)") var tags: String?
    @Option(help: "Filter by command names (comma-separated)") var commands: String?

    func run() async throws {
        let configStore = try ConfigStore(baseDir: defaultConfigDir())
        let sessionManager = SessionManager()
        let tunnelManager = SSHTunnelManager()

        let tagList = tags?.split(separator: ",").map(String.init)
        let cmdList = commands?.split(separator: ",").map(String.init)

        let server = MCPServer(
            configStore: configStore,
            sessionManager: sessionManager,
            tunnelManager: tunnelManager,
            tags: tagList,
            commands: cmdList
        )
        try await server.run()
    }
}

// MARK: - Generate Scripts

struct GenerateScripts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-scripts",
        abstract: "Generate shell scripts for all commands"
    )
    @Option(help: "Output directory") var outputDir: String?

    func run() throws {
        let configStore = try ConfigStore(baseDir: defaultConfigDir())
        let dir = outputDir ?? configStore.globalConfig.scriptOutputDir ?? "~/bin"
        let expanded = NSString(string: dir).expandingTildeInPath
        let paths = try ScriptGenerator.generateAll(configStore: configStore, outputDir: expanded)
        for path in paths {
            print("  generated: \(path)")
        }
    }
}

// MARK: - Install MCP

struct InstallMCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-mcp",
        abstract: "Add sneek to Claude Code MCP config"
    )

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(".claude/settings.json").path
        let sneekdPath = ProcessInfo.processInfo.arguments[0]
        try ScriptGenerator.installMCP(sneekdPath: sneekdPath, settingsPath: settingsPath)
        print("sneek MCP server added to \(settingsPath)")
    }
}
