import SwiftUI
import SneekLib

enum AppLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sneek-app.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var commands: [CommandConfig] = []
    @Published var selectedCommand: String?
    @Published var daemonRunning = false
    @Published var daemonError: String?
    @Published var tunnelStatuses: [String: String] = [:]
    @Published var searchText = ""
    @Published var showFirstRunAlert = false

    private var configStore: ConfigStore?

    var filteredCommands: [CommandConfig] {
        let sorted = commands.sorted { $0.name < $1.name }
        if searchText.isEmpty { return sorted }
        return sorted.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText)
        }
    }

    init() {
        loadConfig()
        refreshStatus()
        checkFirstRun()
        if !daemonRunning {
            startDaemon()
        }
        // Poll daemon status every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func loadConfig() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek")
        do {
            let store = try ConfigStore(baseDir: dir)
            self.configStore = store
            self.commands = Array(store.commands.values)
        } catch {
            AppLog.log("loadConfig failed: \(error)")
        }
    }

    func save(_ command: CommandConfig) {
        do {
            try configStore?.save(command)
            loadConfig()
        } catch {
            AppLog.log("save failed: \(error)")
        }
    }

    func delete(_ name: String) {
        do {
            try configStore?.delete(name)
            if selectedCommand == name { selectedCommand = nil }
            loadConfig()
        } catch {
            AppLog.log("delete failed: \(error)")
        }
    }

    // MARK: - Daemon

    func refreshStatus() {
        let client = IPCClient(socketPath: socketPath)
        do {
            let response = try client.send(IPCRequest(action: .status))
            daemonRunning = response.success
            if daemonRunning {
                daemonError = nil
            }
            if let output = response.output {
                var statuses: [String: String] = [:]
                for line in output.split(separator: "\n") {
                    if line.hasPrefix("tunnel/") {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            let name = String(parts[0]).replacingOccurrences(of: "tunnel/", with: "")
                            statuses[name] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                tunnelStatuses = statuses
            }
        } catch {
            daemonRunning = false
            tunnelStatuses = [:]
        }
    }

    func startDaemon() {
        guard let path = locateSneekd() else {
            let msg = "sneekd binary not found. Build with: swift build"
            daemonError = msg
            AppLog.log("sneekd not found. Searched: \(sneekdCandidates().joined(separator: ", "))")
            return
        }
        AppLog.log("sneekd resolved at: \(path)")
        AppLog.log("starting daemon: \(path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            daemonError = nil
        } catch {
            let msg = "Failed to start sneekd: \(error.localizedDescription)"
            daemonError = msg
            AppLog.log("failed to start daemon: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    func stopDaemon() {
        AppLog.log("stopping daemon")
        let client = IPCClient(socketPath: socketPath)
        _ = try? client.send(IPCRequest(action: .shutdown))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatus()
        }
    }

    // MARK: - sneekd binary resolution

    private func sneekdCandidates() -> [String] {
        var paths: [String] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            paths.append(exeDir.appendingPathComponent("sneekd").path)
        }
        paths.append("/usr/local/bin/sneekd")
        paths.append("/opt/homebrew/bin/sneekd")
        return paths
    }

    private func locateSneekd() -> String? {
        for path in sneekdCandidates() where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return whichSneekd()
    }

    private func whichSneekd() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["sneekd"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    // MARK: - First Run

    func checkFirstRun() {
        let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: claudeSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any],
           servers["sneek"] != nil {
            return
        }
        showFirstRunAlert = true
    }

    func installMCP() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(".claude/settings.json").path
        do {
            try ScriptGenerator.installMCP(sneekdPath: "/usr/local/bin/sneekd", settingsPath: settingsPath)
            AppLog.log("installed MCP entry into \(settingsPath)")
        } catch {
            AppLog.log("installMCP failed: \(error)")
        }
        showFirstRunAlert = false
    }

    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek/sneekd.sock").path
    }
}
