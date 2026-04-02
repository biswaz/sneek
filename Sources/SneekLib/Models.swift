import Foundation

// MARK: - Command Configuration

public struct CommandConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }

    public var name: String
    public var description: String
    public var tags: [String]?
    public var mode: ExecutionMode
    public var idleTimeout: Int?
    public var readonly: Bool?

    public var command: String

    public var secrets: [String: SecretRef]?
    public var variables: [String: String]?

    public var tunnel: TunnelConfig?

    public var setupCommands: [String]?
    public var blockedPatterns: [String]?
    public var sentinel: String?

    public var mcp: MCPConfig?

    enum CodingKeys: String, CodingKey {
        case name, description, tags, mode
        case idleTimeout = "idle_timeout"
        case readonly, command, secrets, variables, tunnel
        case setupCommands = "setup_commands"
        case blockedPatterns = "blocked_patterns"
        case sentinel, mcp
    }

    public init(
        name: String,
        description: String,
        tags: [String]? = nil,
        mode: ExecutionMode,
        idleTimeout: Int? = nil,
        readonly: Bool? = nil,
        command: String,
        secrets: [String: SecretRef]? = nil,
        variables: [String: String]? = nil,
        tunnel: TunnelConfig? = nil,
        setupCommands: [String]? = nil,
        blockedPatterns: [String]? = nil,
        sentinel: String? = nil,
        mcp: MCPConfig? = nil
    ) {
        self.name = name
        self.description = description
        self.tags = tags
        self.mode = mode
        self.idleTimeout = idleTimeout
        self.readonly = readonly
        self.command = command
        self.secrets = secrets
        self.variables = variables
        self.tunnel = tunnel
        self.setupCommands = setupCommands
        self.blockedPatterns = blockedPatterns
        self.sentinel = sentinel
        self.mcp = mcp
    }
}

// MARK: - Execution Mode

public enum ExecutionMode: String, Codable, Equatable, Sendable {
    case session
    case oneshot
}

// MARK: - Secret Reference

public enum SecretRef: Codable, Equatable, Sendable {
    case keychain(key: String)
    case onePassword(ref: String)
    case bitwarden(item: String)
    case env(variable: String)

    enum CodingKeys: String, CodingKey {
        case provider, key, ref, item, variable = "var"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(String.self, forKey: .provider)
        switch provider {
        case "keychain":
            self = .keychain(key: try container.decode(String.self, forKey: .key))
        case "1password":
            self = .onePassword(ref: try container.decode(String.self, forKey: .ref))
        case "bitwarden":
            self = .bitwarden(item: try container.decode(String.self, forKey: .item))
        case "env":
            self = .env(variable: try container.decode(String.self, forKey: .variable))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .provider, in: container,
                debugDescription: "Unknown secret provider: \(provider)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychain(let key):
            try container.encode("keychain", forKey: .provider)
            try container.encode(key, forKey: .key)
        case .onePassword(let ref):
            try container.encode("1password", forKey: .provider)
            try container.encode(ref, forKey: .ref)
        case .bitwarden(let item):
            try container.encode("bitwarden", forKey: .provider)
            try container.encode(item, forKey: .item)
        case .env(let variable):
            try container.encode("env", forKey: .provider)
            try container.encode(variable, forKey: .variable)
        }
    }
}

// MARK: - Tunnel Configuration

public struct TunnelConfig: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var identityKey: String?
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    public var autoConnect: Bool?

    enum CodingKeys: String, CodingKey {
        case host, user
        case identityKey = "identity_key"
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
        case autoConnect = "auto_connect"
    }

    public init(
        host: String,
        user: String,
        identityKey: String? = nil,
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        autoConnect: Bool? = nil
    ) {
        self.host = host
        self.user = user
        self.identityKey = identityKey
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoConnect = autoConnect
    }
}

// MARK: - MCP Configuration

public struct MCPConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var toolName: String
    public var toolDescription: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case toolName = "tool_name"
        case toolDescription = "tool_description"
    }

    public init(enabled: Bool, toolName: String, toolDescription: String) {
        self.enabled = enabled
        self.toolName = toolName
        self.toolDescription = toolDescription
    }
}

// MARK: - Global Configuration

public struct SneekConfig: Codable, Equatable, Sendable {
    public var scriptOutputDir: String?
    public var logLevel: String?

    enum CodingKeys: String, CodingKey {
        case scriptOutputDir = "script_output_dir"
        case logLevel = "log_level"
    }

    public init(scriptOutputDir: String? = nil, logLevel: String? = nil) {
        self.scriptOutputDir = scriptOutputDir
        self.logLevel = logLevel
    }
}

// MARK: - Tunnel Status

public enum TunnelStatus: Equatable, Sendable {
    case up
    case down
    case reconnecting
}
