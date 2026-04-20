import SwiftUI
import SneekLib

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header with daemon toggle
            HStack {
                Text("Sneek").font(.headline)
                Spacer()
                DaemonToggle()
                    .environmentObject(appState)
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
                        CommandRow(command: cmd, tunnelStatus: appState.tunnelStatuses[cmd.name])
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(max(appState.filteredCommands.count, 1)) * 52 + 8, 400))

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
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.caption)

                Spacer()

                Button("Open Window ↗") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
        .onAppear { appState.refreshStatus() }
        .alert("Set up Claude Code?", isPresented: $appState.showFirstRunAlert) {
            Button("Install MCP") { appState.installMCP() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Sneek can integrate with Claude Code so your commands appear as MCP tools. Set it up now?")
        }
    }
}

struct DaemonToggle: View {
    @EnvironmentObject var appState: AppState

    private enum DaemonState {
        case running, stopped, error
    }

    private var state: DaemonState {
        if appState.daemonError != nil { return .error }
        return appState.daemonRunning ? .running : .stopped
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .stopped: return .secondary
        case .error:   return .orange
        }
    }

    private var label: String {
        switch state {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .error:   return "Error"
        }
    }

    private var tooltip: String {
        switch state {
        case .running: return "Click to stop daemon"
        case .stopped: return "Click to start daemon"
        case .error:   return appState.daemonError ?? "Daemon error"
        }
    }

    var body: some View {
        Button {
            if appState.daemonRunning { appState.stopDaemon() }
            else { appState.startDaemon() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.caption).fontWeight(.medium).foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

struct CommandRow: View {
    let command: CommandConfig
    let tunnelStatus: String?

    private var isDisabled: Bool { command.enabled == false }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name).font(.system(.body, weight: .semibold))
                Text(command.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if isDisabled {
                    Badge(text: "off", color: .gray)
                }
                if command.tunnel != nil {
                    let status = tunnelStatus ?? "down"
                    let color: Color = status == "up" ? .green : status == "reconnecting" ? .yellow : .red
                    Badge(text: "tunnel", color: color)
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
        .opacity(isDisabled ? 0.5 : 1.0)
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
