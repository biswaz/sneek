import SwiftUI
import SneekLib

@MainActor
final class AppState: ObservableObject {
    @Published var commands: [CommandConfig] = []
    @Published var selectedCommand: String?
    @Published var daemonRunning = false
    @Published var tunnelStatuses: [String: TunnelStatus] = [:]
    @Published var searchText = ""

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

    func refreshStatus() {
        let client = IPCClient(socketPath: socketPath)
        do {
            let response = try client.send(IPCRequest(action: .status))
            daemonRunning = response.success
        } catch {
            daemonRunning = false
        }
    }

    private var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek/sneekd.sock").path
    }
}
