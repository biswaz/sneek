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

    private var pollTimer: DispatchSourceTimer?
    private var lastCommandsHash: Int = 0

    public func startWatching() {
        // DispatchSource for directory-level changes (file add/remove)
        let fd = open(commandsDir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.checkAndReload()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            dispatchSource = source
        }

        // Poll every 3 seconds for content changes (edits to existing files)
        lastCommandsHash = computeHash()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            self?.checkAndReload()
        }
        timer.resume()
        pollTimer = timer
    }

    public func stopWatching() {
        dispatchSource?.cancel()
        pollTimer?.cancel()
        pollTimer = nil
        dispatchSource = nil
    }

    private func checkAndReload() {
        let newHash = computeHash()
        if newHash != lastCommandsHash {
            lastCommandsHash = newHash
            try? reload()
            onChange?()
        }
    }

    private func computeHash() -> Int {
        var hash = 0
        if let files = try? FileManager.default.contentsOfDirectory(
            at: commandsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "json" }) {
            for file in files {
                hash ^= file.lastPathComponent.hashValue
                if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                   let date = attrs.contentModificationDate {
                    hash ^= date.hashValue
                }
            }
        }
        return hash
    }
}
