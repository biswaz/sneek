import SwiftUI
import SneekLib

@MainActor
final class AppState: ObservableObject {
    @Published var commands: [CommandConfig] = []
    @Published var selectedCommand: String?
    @Published var daemonRunning = false
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
            print("Failed to load config: \(error)")
        }
    }

    func save(_ command: CommandConfig) {
        do {
            try configStore?.save(command)
            loadConfig()
        } catch {
            print("Failed to save: \(error)")
        }
    }

    func delete(_ name: String) {
        do {
            try configStore?.delete(name)
            if selectedCommand == name { selectedCommand = nil }
            loadConfig()
        } catch {
            print("Failed to delete: \(error)")
        }
    }

    // MARK: - Daemon

    func refreshStatus() {
        let client = IPCClient(socketPath: socketPath)
        do {
            let response = try client.send(IPCRequest(action: .status))
            daemonRunning = response.success
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sneekd", "start"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshStatus()
        }
    }

    func stopDaemon() {
        let client = IPCClient(socketPath: socketPath)
        _ = try? client.send(IPCRequest(action: .shutdown))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshStatus()
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
        try? ScriptGenerator.installMCP(sneekdPath: "/usr/local/bin/sneekd", settingsPath: settingsPath)
        showFirstRunAlert = false
    }

    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek/sneekd.sock").path
    }
}
