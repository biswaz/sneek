import Foundation

public actor Daemon {
    public let configStore: ConfigStore
    public let sessionManager: SessionManager
    public let tunnelManager: SSHTunnelManager
    private let ipcServer: IPCServer

    public init(configStore: ConfigStore) {
        self.configStore = configStore
        self.sessionManager = SessionManager()
        self.tunnelManager = SSHTunnelManager()

        let socketPath = configStore.baseDir.appendingPathComponent("sneekd.sock").path
        self.ipcServer = IPCServer(socketPath: socketPath)
    }

    public func start() async throws {
        // Initialize logger
        let logsDir = configStore.baseDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        SneekLogger.logFile = logsDir.appendingPathComponent("sneekd.log")

        SneekLogger.info("daemon: starting")
        try ipcServer.start()

        // Watch for config changes — start tunnels for newly enabled commands
        configStore.onChange = { [weak self] in
            guard let self else { return }
            Task {
                for (name, cmd) in self.configStore.commands {
                    if cmd.enabled == false {
                        // Tear down tunnel and reap session for disabled commands
                        try? await self.tunnelManager.tearDown(name)
                        await self.sessionManager.reap(name)
                        continue
                    }
                    if let tunnel = cmd.tunnel, tunnel.enabled != false {
                        if tunnel.autoConnect == true {
                            try? await self.tunnelManager.ensureUp(name, tunnel: tunnel)
                        }
                    } else {
                        // Tunnel config removed or disabled — tear down if running
                        try? await self.tunnelManager.tearDown(name)
                    }
                }
            }
        }
        configStore.startWatching()

        let sessionMgr = sessionManager
        let tunnelMgr = tunnelManager
        let store = configStore

        ipcServer.handler = { [weak self] request in
            SneekLogger.debug("daemon: IPC request received: \(request.action)")
            if request.action == .shutdown {
                SneekLogger.info("daemon: shutdown requested via IPC")
                Task { await self?.stop(); Foundation.exit(0) }
                return .ok("shutting down")
            }
            return await Self.handleRequest(request, configStore: store, sessionManager: sessionMgr, tunnelManager: tunnelMgr)
        }

        // Start auto-connect tunnels (skip disabled commands and disabled tunnels)
        for (name, cmd) in configStore.commands {
            if cmd.enabled == false { continue }
            if let tunnel = cmd.tunnel, tunnel.enabled != false, tunnel.autoConnect == true {
                try? await tunnelManager.ensureUp(name, tunnel: tunnel)
            }
        }

        await tunnelManager.startMonitoring()
        await ipcServer.acceptLoop()
    }

    public func stop() async {
        SneekLogger.info("daemon: stopping")
        configStore.stopWatching()
        ipcServer.stop()
        await tunnelManager.stopMonitoring()
        await sessionManager.reapAll()
        await tunnelManager.tearDownAll()
    }

    // MARK: - Request Handling

    private static func handleRequest(
        _ request: IPCRequest,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        switch request.action {
        case .status:
            return await statusResponse(configStore: configStore, sessionManager: sessionManager, tunnelManager: tunnelManager)

        case .run:
            guard let cmdName = request.command else {
                return .fail("missing command name")
            }
            return await runCommand(name: cmdName, input: request.input, configStore: configStore, sessionManager: sessionManager, tunnelManager: tunnelManager)

        case .tunnel:
            guard let cmdName = request.command, let op = request.operation else {
                return .fail("missing command name or operation")
            }
            return await tunnelOp(name: cmdName, operation: op, configStore: configStore, tunnelManager: tunnelManager)

        case .list:
            let names = configStore.commands.keys.sorted()
            return .ok(names.joined(separator: "\n"))

        case .shutdown:
            return .ok("shutting down")
        }
    }

    private static func statusResponse(
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        var lines: [String] = ["daemon: running"]

        let sessions = await sessionManager.activeSessions()
        lines.append("sessions: \(sessions.count)")

        for (name, cmd) in configStore.commands {
            if cmd.tunnel != nil {
                let ts = await tunnelManager.status(name)
                lines.append("tunnel/\(name): \(ts)")
            }
        }

        return .ok(lines.joined(separator: "\n"))
    }

    private static func runCommand(
        name: String,
        input: String?,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        guard let cmd = configStore.commands[name] else {
            return .fail("unknown command: \(name)")
        }
        if cmd.enabled == false {
            return .fail("command '\(name)' is disabled")
        }

        SneekLogger.info("daemon: executing command '\(name)' (mode: \(cmd.mode))")

        // Resolve secrets + variables
        let resolver = SecretResolver(
            secrets: cmd.secrets ?? [:],
            variables: cmd.variables ?? [:]
        )

        let allVars: [String: String]
        do {
            allVars = try await resolver.resolveAll()
        } catch {
            return .fail("secret resolution failed: \(error)")
        }

        // Add local_port from tunnel if present
        var vars = allVars
        if let tunnel = cmd.tunnel {
            vars["local_port"] = String(tunnel.localPort)
        }

        // Interpolate command template
        let resolvedCommand: String
        do {
            resolvedCommand = try TemplateEngine.render(cmd.command, variables: vars)
        } catch {
            return .fail("template error: \(error)")
        }

        // Ensure tunnel is up (if configured and enabled)
        if let tunnel = cmd.tunnel, tunnel.enabled != false {
            do {
                try await tunnelManager.ensureUp(name, tunnel: tunnel)
            } catch {
                return .fail("tunnel failed: \(error)")
            }
        }

        // Execute
        do {
            let result: String
            switch cmd.mode {
            case .session:
                guard let input = input else {
                    return .fail("session mode requires input")
                }
                result = try await sessionManager.send(input: input, to: name, config: cmd, resolvedCommand: resolvedCommand)
            case .oneshot:
                result = try await sessionManager.runOneshot(command: resolvedCommand, input: input)
            }
            return .ok(result)
        } catch {
            return .fail("execution failed: \(error)")
        }
    }

    private static func tunnelOp(
        name: String,
        operation: String,
        configStore: ConfigStore,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        guard let cmd = configStore.commands[name], let tunnel = cmd.tunnel else {
            return .fail("no tunnel config for: \(name)")
        }

        switch operation {
        case "up":
            do {
                try await tunnelManager.ensureUp(name, tunnel: tunnel)
                return .ok("tunnel up")
            } catch {
                return .fail("tunnel up failed: \(error)")
            }
        case "down":
            do {
                try await tunnelManager.tearDown(name)
                return .ok("tunnel down")
            } catch {
                return .fail("tunnel down failed: \(error)")
            }
        case "status":
            let s = await tunnelManager.status(name)
            return .ok("\(s)")
        default:
            return .fail("unknown tunnel operation: \(operation)")
        }
    }
}
