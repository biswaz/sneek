import SwiftUI
import SneekLib

struct CommandEditorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(appState.filteredCommands, selection: $appState.selectedCommand) { cmd in
                Text(cmd.name)
            }
            .searchable(text: $appState.searchText, prompt: "Filter commands")
            .toolbar {
                Button {
                    let newCmd = CommandConfig(
                        name: "new-command-\(Int.random(in: 1000...9999))",
                        description: "New command",
                        mode: .oneshot,
                        command: "echo hello"
                    )
                    appState.save(newCmd)
                    appState.selectedCommand = newCmd.name
                } label: {
                    Image(systemName: "plus")
                }
            }
        } detail: {
            if let name = appState.selectedCommand,
               let cmd = appState.commands.first(where: { $0.name == name }) {
                CommandFormView(command: cmd)
                    .id(name) // force refresh when selection changes
            } else {
                Text("Select a command")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CommandFormView: View {
    @EnvironmentObject var appState: AppState
    @State private var name: String
    @State private var description: String
    @State private var mode: ExecutionMode
    @State private var command: String
    @State private var readonly: Bool
    @State private var tags: String

    // Tunnel
    @State private var hasTunnel: Bool
    @State private var tunnelHost: String
    @State private var tunnelUser: String
    @State private var tunnelIdentityKey: String
    @State private var tunnelLocalPort: String
    @State private var tunnelRemoteHost: String
    @State private var tunnelRemotePort: String

    // MCP
    @State private var mcpEnabled: Bool
    @State private var mcpToolName: String
    @State private var mcpToolDescription: String

    // Setup
    @State private var setupCommands: String
    @State private var blockedPatterns: String

    private let originalName: String

    init(command: CommandConfig) {
        self.originalName = command.name
        _name = State(initialValue: command.name)
        _description = State(initialValue: command.description)
        _mode = State(initialValue: command.mode)
        _command = State(initialValue: command.command)
        _readonly = State(initialValue: command.readonly ?? false)
        _tags = State(initialValue: (command.tags ?? []).joined(separator: ", "))

        let t = command.tunnel
        _hasTunnel = State(initialValue: t != nil)
        _tunnelHost = State(initialValue: t?.host ?? "")
        _tunnelUser = State(initialValue: t?.user ?? "")
        _tunnelIdentityKey = State(initialValue: t?.identityKey ?? "")
        _tunnelLocalPort = State(initialValue: t.map { String($0.localPort) } ?? "")
        _tunnelRemoteHost = State(initialValue: t?.remoteHost ?? "")
        _tunnelRemotePort = State(initialValue: t.map { String($0.remotePort) } ?? "")

        _mcpEnabled = State(initialValue: command.mcp?.enabled ?? false)
        _mcpToolName = State(initialValue: command.mcp?.toolName ?? "")
        _mcpToolDescription = State(initialValue: command.mcp?.toolDescription ?? "")

        _setupCommands = State(initialValue: (command.setupCommands ?? []).joined(separator: "\n"))
        _blockedPatterns = State(initialValue: (command.blockedPatterns ?? []).joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
                TextField("Tags", text: $tags)
                    .help("Comma-separated tags for filtering")
                Picker("Mode", selection: $mode) {
                    Text("Session").tag(ExecutionMode.session)
                    Text("Oneshot").tag(ExecutionMode.oneshot)
                }
            }

            Section("Command Template") {
                TextField("Command", text: $command, axis: .vertical)
                    .lineLimit(3...6)
                    .font(.system(.body, design: .monospaced))
            }

            Section("Access Control") {
                Toggle("Read-Only", isOn: $readonly)
                if readonly {
                    TextField("Setup Commands", text: $setupCommands, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(.body, design: .monospaced))
                        .help("Commands run at session start (one per line)")
                    TextField("Blocked Patterns", text: $blockedPatterns)
                        .help("Comma-separated patterns to reject (e.g. DROP, DELETE)")
                }
            }

            Section("SSH Tunnel") {
                Toggle("Enable Tunnel", isOn: $hasTunnel)
                if hasTunnel {
                    TextField("Bastion Host", text: $tunnelHost)
                    TextField("SSH User", text: $tunnelUser)
                    TextField("Identity Key", text: $tunnelIdentityKey)
                    HStack {
                        TextField("Local Port", text: $tunnelLocalPort)
                        TextField("Remote Host", text: $tunnelRemoteHost)
                        TextField("Remote Port", text: $tunnelRemotePort)
                    }
                }
            }

            Section("Claude MCP Integration") {
                Toggle("Expose via MCP", isOn: $mcpEnabled)
                if mcpEnabled {
                    TextField("Tool Name", text: $mcpToolName)
                    TextField("Tool Description", text: $mcpToolDescription)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete", role: .destructive) {
                    appState.delete(originalName)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
    }

    private func save() {
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let tunnel: TunnelConfig? = hasTunnel ? TunnelConfig(
            host: tunnelHost,
            user: tunnelUser,
            identityKey: tunnelIdentityKey.isEmpty ? nil : tunnelIdentityKey,
            localPort: Int(tunnelLocalPort) ?? 0,
            remoteHost: tunnelRemoteHost,
            remotePort: Int(tunnelRemotePort) ?? 0
        ) : nil

        let mcp: MCPConfig? = mcpEnabled ? MCPConfig(
            enabled: true,
            toolName: mcpToolName,
            toolDescription: mcpToolDescription
        ) : nil

        let setupCmds = setupCommands.isEmpty ? nil : setupCommands.split(separator: "\n").map(String.init)
        let blocked = blockedPatterns.isEmpty ? nil : blockedPatterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let cmd = CommandConfig(
            name: name,
            description: description,
            tags: tagList.isEmpty ? nil : tagList,
            mode: mode,
            readonly: readonly ? true : nil,
            command: command,
            tunnel: tunnel,
            setupCommands: setupCmds,
            blockedPatterns: blocked,
            mcp: mcp
        )

        // If name changed, delete old
        if name != originalName {
            appState.delete(originalName)
        }

        appState.save(cmd)
        appState.selectedCommand = name
    }
}
