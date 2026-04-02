# Sneek — Backlog

Prioritized by impact. Items marked **(spec)** were in the design spec but not implemented. Items marked **(discovered)** were found during development/testing.

## P0 — Blocking real usage

1. **No variables/secrets editor in the GUI.** **(spec)** The command editor has General, Command Template, Access Control, SSH Tunnel, MCP sections — but no key-value editor for `variables` and `secrets` maps. You must edit JSON directly. This is the single biggest gap for non-technical users.
2. **Daemon runs foreground only.** **(spec)** `sneekd start` blocks the terminal. No `sneekd install` command to create `~/Library/LaunchAgents/com.sneek.daemon.plist` for auto-start on login. No PID file written. `sneekd stop` only works via IPC (daemon must already be running).
3. `**sneekd mcp-serve` creates its own managers.** **(discovered)** The MCP server process creates its own `SessionManager` and `SSHTunnelManager` instead of connecting to the running daemon via IPC. This means tunnels and sessions aren't shared between CLI usage and MCP usage. If the daemon has a tunnel up, MCP doesn't know about it.
4. **Session mode requires input on every call.** **(discovered)** `Daemon.swift:150` returns error if `input` is nil for session mode. Can't do `sneekd run pg-prod` to open an interactive session — must always provide input: `sneekd run pg-prod "SELECT 1"`. The spec describes both interactive and one-shot usage.
5. **IPC buffer is 4096 bytes.** **(discovered)** `IPCProtocol.swift:92` — large query results will be truncated. Needs chunked reading or a larger/dynamic buffer.

## P1 — Important for reliability

1. **No tunnel auto-reconnect loop.** **(spec)** `SSHTunnelManager` checks tunnel health only when a command is run. No background monitoring, no exponential backoff retry. Spec says: "Health monitoring — daemon checks tunnel liveness periodically" and "Auto-reconnect — exponential backoff on failure." Neither is implemented.
2. **Config file watching not activated.** **(discovered)** `ConfigStore.startWatching()` exists but `Daemon.swift` never calls it. Config changes (from GUI or manual JSON edits) aren't picked up until daemon restart.
3. **SSH identity key tilde not expanded.** **(discovered)** `TunnelManager.swift:84` passes `tunnel.identityKey` directly to `ssh -i`. If the key is `~/.ssh/prod_key`, the tilde isn't expanded, so SSH can't find it.
4. **Session stderr is discarded.** **(discovered)** `SessionManager.swift:121` sets `process.standardError = FileHandle.nullDevice`. If psql prints an error, the user never sees it. Stderr should be captured and returned alongside stdout.
5. **Setup command failures are silent.** **(discovered)** `SessionManager.swift:136-142` sends setup commands and reads until sentinel, but doesn't check if the command succeeded. If `SET default_transaction_read_only = on;` fails (wrong syntax, wrong DB), the session continues as read-write.
6. **No logging.** **(spec)** Config has `logLevel` field, `~/.config/sneek/logs/` is in the spec, but nothing is ever logged anywhere.

## P2 — Nice to have

1. **No auto-fill for known command types.** **(spec)** GUI should auto-fill setup commands and blocked patterns when you select Postgres/MySQL/Redis and toggle read-only. Not implemented.
2. **Live tunnel status in GUI.** **(spec)** `AppState.tunnelStatuses` property exists but is never populated. Menubar badges show based on config (tunnel field exists), not actual daemon status. Should poll daemon via IPC.
3. **1Password/Bitwarden CLI paths hardcoded.** **(discovered)** `SecretResolver.swift:75` hardcodes `/usr/local/bin/op`, line 83 hardcodes `/usr/local/bin/bw`. Should use `which` or allow path override in config.
4. **No global settings UI.** **(spec)** Global config (`script_output_dir`, `log_level`) can only be set by editing `~/.config/sneek/config.json` directly. No GUI for it.
5. **No first-run setup flow.** **(spec)** App should offer to install MCP config and configure script output dir on first launch. Currently requires manual `sneekd install-mcp`.
6. **GUI doesn't start/stop daemon.** **(spec)** AppState has `refreshStatus()` but no `startDaemon()`/`stopDaemon()`. App should offer to start the daemon if it detects it's not running.
7. `**Process.waitUntilExit()` blocks thread in secret resolution.** **(discovered)** `SecretResolver.swift:38` — the `runProcess` helper blocks a thread while waiting for `security`/`op`/`bw` to finish. Should use async process handling.
8. **Health check timeout hardcoded.** **(discovered)** `TunnelManager.swift:66` uses 1.0s for health check, line 97 sleeps 0.5s before checking. Both may be too short for slow networks. Should be configurable or use exponential retry.

## Testing gaps

1. **SSH tunnel integration test skipped** unless Remote Login is enabled in System Settings. Test exists but prints "(skipped)".
2. **No real 1Password/Bitwarden tests.** Tested with mocks only (`InMemoryProvider`). Real CLI integration needs auth sessions.
3. **No GUI tests.** SwiftUI UI testing is fragile — all GUI testing is manual for v1.
4. **No idle timeout integration test.** Timer-based reaping exists but isn't tested with a real timeout (would need to wait 300s or make timeout configurable in test).
5. **No large output test.** IPC buffer truncation (item 5) isn't tested.

