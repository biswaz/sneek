import SwiftUI
import SneekLib

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Sneek").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.daemonRunning ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(appState.daemonRunning ? "running" : "stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Search
            TextField("Search commands...", text: $appState.searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            // Command list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(appState.filteredCommands) { cmd in
                        CommandRow(command: cmd)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)

            Divider()

            // Footer
            HStack {
                Button("+ New Command") {
                    let newCmd = CommandConfig(
                        name: "new-command",
                        description: "New command",
                        mode: .oneshot,
                        command: "echo hello"
                    )
                    appState.save(newCmd)
                    appState.selectedCommand = newCmd.name
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                Button("Open Window ↗") {
                    openWindow(id: "main")
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .onAppear { appState.refreshStatus() }
    }
}

struct CommandRow: View {
    let command: CommandConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name).font(.system(.body, weight: .semibold))
                Text(command.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if command.tunnel != nil {
                    Badge(text: "tunnel", color: .green)
                }
                if command.mcp?.enabled == true {
                    Badge(text: "MCP", color: .purple)
                }
                if command.readonly == true {
                    Badge(text: "RO", color: .orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
