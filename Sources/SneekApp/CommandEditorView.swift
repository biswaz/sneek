import SwiftUI
import SneekLib

struct CommandEditorView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
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
                    .id(name)
            } else {
                Text("Select a command")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Helper types for dynamic rows

struct VariableRow: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct SecretRow: Identifiable {
    let id = UUID()
    var key: String
    var provider: String  // "keychain", "1password", "bitwarden", "env"
    var reference: String // the key/ref/item/var value
}

enum KnownCommandType: String, CaseIterable {
    case postgres = "Postgres"
    case mysql = "MySQL"
    case redis = "Redis"
    case custom = "Custom"

    var defaultSetupCommands: String {
        switch self {
        case .postgres: return "SET default_transaction_read_only = on;"
        case .mysql: return "SET SESSION TRANSACTION READ ONLY;"
        case .redis: return ""
        case .custom: return ""
        }
    }

    var defaultBlockedPatterns: String {
        switch self {
        case .postgres, .mysql: return "DROP, DELETE, UPDATE, INSERT, ALTER, TRUNCATE"
        case .redis: return "DEL, FLUSHDB, FLUSHALL, SET, EXPIRE"
        case .custom: return ""
        }
    }

    var defaultSentinel: String {
        switch self {
        case .postgres: return #"\echo __SNEEK_DONE__"#
        case .mysql: return "SELECT '__SNEEK_DONE__';"
        case .redis: return "ECHO __SNEEK_DONE__"
        case .custom: return "echo __SNEEK_DONE__"
        }
    }
}

// MARK: - Form

struct CommandFormView: View {
    @EnvironmentObject var appState: AppState
    @State private var name: String
    @State private var description: String
    @State private var enabled: Bool
    @State private var mode: ExecutionMode
    @State private var command: String
    @State private var readonly: Bool
    @State private var tags: String

    // Variables & Secrets
    @State private var variables: [VariableRow]
    @State private var secrets: [SecretRow]

    // Tunnel
    @State private var hasTunnel: Bool
    @State private var tunnelHost: String
    @State private var tunnelUser: String
    @State private var tunnelIdentityKey: String
    @State private var tunnelLocalPort: String
    @State private var tunnelRemoteHost: String
    @State private var tunnelRemotePort: String
    @State private var tunnelAutoConnect: Bool

    // MCP
    @State private var mcpEnabled: Bool
    @State private var mcpToolName: String
    @State private var mcpToolDescription: String

    // Access control
    @State private var setupCommands: String
    @State private var blockedPatterns: String

    private let originalName: String

    init(command: CommandConfig) {
        self.originalName = command.name
        _name = State(initialValue: command.name)
        _description = State(initialValue: command.description)
        _enabled = State(initialValue: command.enabled ?? true)
        _mode = State(initialValue: command.mode)
        _command = State(initialValue: command.command)
        _readonly = State(initialValue: command.readonly ?? false)
        _tags = State(initialValue: (command.tags ?? []).joined(separator: ", "))

        // Convert variables dict to rows
        _variables = State(initialValue: (command.variables ?? [:]).map { VariableRow(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key })

        // Convert secrets dict to rows
        _secrets = State(initialValue: (command.secrets ?? [:]).map { entry in
            let (provider, ref): (String, String) = {
                switch entry.value {
                case .keychain(let key): return ("keychain", key)
                case .onePassword(let ref): return ("1password", ref)
                case .bitwarden(let item): return ("bitwarden", item)
                case .env(let variable): return ("env", variable)
                }
            }()
            return SecretRow(key: entry.key, provider: provider, reference: ref)
        }.sorted { $0.key < $1.key })

        let t = command.tunnel
        _hasTunnel = State(initialValue: t != nil)
        _tunnelHost = State(initialValue: t?.host ?? "")
        _tunnelUser = State(initialValue: t?.user ?? "")
        _tunnelIdentityKey = State(initialValue: t?.identityKey ?? "")
        _tunnelLocalPort = State(initialValue: t.map { String($0.localPort) } ?? "")
        _tunnelRemoteHost = State(initialValue: t?.remoteHost ?? "")
        _tunnelRemotePort = State(initialValue: t.map { String($0.remotePort) } ?? "")
        _tunnelAutoConnect = State(initialValue: t?.autoConnect ?? false)

        _mcpEnabled = State(initialValue: command.mcp?.enabled ?? false)
        _mcpToolName = State(initialValue: command.mcp?.toolName ?? "")
        _mcpToolDescription = State(initialValue: command.mcp?.toolDescription ?? "")

        _setupCommands = State(initialValue: (command.setupCommands ?? []).joined(separator: "\n"))
        _blockedPatterns = State(initialValue: (command.blockedPatterns ?? []).joined(separator: ", "))
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Enabled", isOn: $enabled)
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
                Text("Use {{variable_name}} for interpolation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Variables") {
                ForEach($variables) { $row in
                    HStack {
                        TextField("Key", text: $row.key)
                            .frame(width: 120)
                        TextField("Value", text: $row.value)
                        Button(role: .destructive) {
                            variables.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Variable") {
                    variables.append(VariableRow(key: "", value: ""))
                }
                .font(.caption)
            }

            Section("Secrets") {
                ForEach($secrets) { $row in
                    HStack {
                        TextField("Variable", text: $row.key)
                            .frame(width: 100)
                        Picker("", selection: $row.provider) {
                            Text("Keychain").tag("keychain")
                            Text("1Password").tag("1password")
                            Text("Bitwarden").tag("bitwarden")
                            Text("Env Var").tag("env")
                        }
                        .frame(width: 110)
                        TextField("Key / Reference", text: $row.reference)
                        Button(role: .destructive) {
                            secrets.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Secret") {
                    secrets.append(SecretRow(key: "", provider: "keychain", reference: ""))
                }
                .font(.caption)
                Text("Secrets are never stored — only the provider reference is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Access Control") {
                Toggle("Read-Only", isOn: $readonly)
                if readonly {
                    Picker("Presets", selection: Binding(
                        get: { KnownCommandType.custom },
                        set: { type in
                            setupCommands = type.defaultSetupCommands
                            blockedPatterns = type.defaultBlockedPatterns
                        }
                    )) {
                        ForEach(KnownCommandType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .help("Auto-fill setup commands and blocked patterns for known types")

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
                    Toggle("Auto-connect on daemon start", isOn: $tunnelAutoConnect)
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

        // Convert variable rows to dict
        var varsDict: [String: String]? = nil
        let filteredVars = variables.filter { !$0.key.isEmpty }
        if !filteredVars.isEmpty {
            varsDict = Dictionary(uniqueKeysWithValues: filteredVars.map { ($0.key, $0.value) })
        }

        // Convert secret rows to dict
        var secretsDict: [String: SecretRef]? = nil
        let filteredSecrets = secrets.filter { !$0.key.isEmpty && !$0.reference.isEmpty }
        if !filteredSecrets.isEmpty {
            secretsDict = [:]
            for row in filteredSecrets {
                let ref: SecretRef
                switch row.provider {
                case "keychain": ref = .keychain(key: row.reference)
                case "1password": ref = .onePassword(ref: row.reference)
                case "bitwarden": ref = .bitwarden(item: row.reference)
                case "env": ref = .env(variable: row.reference)
                default: ref = .keychain(key: row.reference)
                }
                secretsDict?[row.key] = ref
            }
        }

        let tunnel: TunnelConfig? = hasTunnel ? TunnelConfig(
            host: tunnelHost,
            user: tunnelUser,
            identityKey: tunnelIdentityKey.isEmpty ? nil : tunnelIdentityKey,
            localPort: Int(tunnelLocalPort) ?? 0,
            remoteHost: tunnelRemoteHost,
            remotePort: Int(tunnelRemotePort) ?? 0,
            autoConnect: tunnelAutoConnect ? true : nil
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
            enabled: enabled ? nil : false,
            tags: tagList.isEmpty ? nil : tagList,
            mode: mode,
            readonly: readonly ? true : nil,
            command: command,
            secrets: secretsDict,
            variables: varsDict,
            tunnel: tunnel,
            setupCommands: setupCmds,
            blockedPatterns: blocked,
            mcp: mcp
        )

        if name != originalName {
            appState.delete(originalName)
        }

        appState.save(cmd)
        appState.selectedCommand = name
    }
}
