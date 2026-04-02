import Foundation

public final class ConfigStore: @unchecked Sendable {
    public let baseDir: URL
    public let commandsDir: URL

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private var dispatchSource: DispatchSourceFileSystemObject?

    public private(set) var commands: [String: CommandConfig] = [:]
    public private(set) var globalConfig: SneekConfig = SneekConfig()

    public var onChange: (() -> Void)?

    public init(baseDir: URL) throws {
        self.baseDir = baseDir
        self.commandsDir = baseDir.appendingPathComponent("commands")
        try FileManager.default.createDirectory(at: commandsDir, withIntermediateDirectories: true)
        try reload()
    }

    public func reload() throws {
        commands = [:]
        let configPath = baseDir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configPath.path) {
            let data = try Data(contentsOf: configPath)
            globalConfig = try decoder.decode(SneekConfig.self, from: data)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: commandsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }

        for file in files {
            let data = try Data(contentsOf: file)
            let config = try decoder.decode(CommandConfig.self, from: data)
            commands[config.name] = config
        }
    }

    public func save(_ command: CommandConfig) throws {
        let data = try encoder.encode(command)
        let path = commandsDir.appendingPathComponent("\(command.name).json")
        try data.write(to: path)
        commands[command.name] = command
    }

    public func delete(_ name: String) throws {
        let path = commandsDir.appendingPathComponent("\(name).json")
        try FileManager.default.removeItem(at: path)
        commands.removeValue(forKey: name)
    }

    public func saveGlobalConfig(_ config: SneekConfig) throws {
        let data = try encoder.encode(config)
        let path = baseDir.appendingPathComponent("config.json")
        try data.write(to: path)
        globalConfig = config
    }

    public func startWatching() {
        let fd = open(commandsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            try? self?.reload()
            self?.onChange?()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dispatchSource = source
    }

    public func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }
}
