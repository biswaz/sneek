# Sneek — Backlog

Prioritized by impact. Items marked **(spec)** were in the design spec. Items marked **(discovered)** were found during development/testing.

## P0 — Blocking real usage

1. ~~No variables/secrets editor in the GUI.~~ **DONE** — Key-value editors for variables and secrets with provider picker (Keychain/1Password/Bitwarden/Env).
2. ~~Daemon runs foreground only.~~ **DONE** — `sneekd install` creates launchd plist for auto-start. PID file written. `sneekd uninstall` removes it.
3. ~~`sneekd mcp-serve` creates its own managers.~~ **DONE** — MCP delegates to daemon via IPC.
4. **Config reload not working in daemon/CLI.** **(discovered)** `sneekd list` and daemon IPC calls re-read config from disk each time (creating a new `ConfigStore`), but `sneekd list` is fast. The real issue: the daemon's `ConfigStore` instance is loaded once at startup. The `startWatching()` DispatchSource fires on directory changes, but `reload()` only updates the in-memory `commands` dict — the daemon's `handleRequest` already captured `configStore` by reference so it sees updates. However, `sneekd list` creates its own `ConfigStore` each time so it always sees fresh data. **The bug is likely that new files added to the commands dir don't trigger the DispatchSource `.write` event consistently.** Needs investigation.
5. **Session mode requires input on every call.** **(discovered)** `Daemon.swift:196` returns error if `input` is nil for session mode. Can't do `sneekd run pg-prod` interactively. Works fine for MCP (Claude always sends input).
6. ~~IPC buffer is 4096 bytes.~~ **DONE** — Buffer 65KB, delimiter check on accumulated data.

## P1 — Important for reliability

1. ~~No tunnel auto-reconnect loop.~~ **DONE** — Background monitoring every 10s, exponential backoff 1s-30s.
2. ~~Config file watching not activated.~~ **DONE** — Daemon calls `startWatching()` on startup.
3. ~~SSH identity key tilde not expanded.~~ **DONE** — Uses `NSString.expandingTildeInPath`.
4. ~~Session stderr is discarded.~~ **DONE** — Stderr merged into stdout.
5. ~~Setup command failures are silent.~~ **DONE** — Output checked for error/fatal/denied.
6. ~~No logging.~~ **DONE** — `SneekLogger` writes to `~/.config/sneek/logs/sneekd.log` + stderr for warnings.

## P2 — Nice to have

1. ~~No auto-fill for known command types.~~ **DONE** — Presets picker for Postgres, MySQL, Redis auto-fills setup commands + blocked patterns.
2. ~~Live tunnel status in GUI.~~ **DONE** — Polls daemon every 5s, tunnel badges show green/yellow/red.
3. ~~1Password/Bitwarden CLI paths hardcoded.~~ **DONE** — Uses `which` to find CLI, falls back to `/usr/local/bin`.
4. **No global settings UI.** **(spec)** Edit `~/.config/sneek/config.json` directly.
5. ~~No first-run setup flow.~~ **DONE** — Alert on first launch offers to install MCP config.
6. ~~GUI doesn't start/stop daemon.~~ **DONE** — Click daemon status indicator to toggle.
7. **`Process.waitUntilExit()` blocks thread in secret resolution.** **(discovered)** Should use async process handling. Low priority — works fine in practice.
8. **Health check timeout hardcoded.** **(discovered)** 1.0s for check, 0.5s initial delay. Configurable would be nice for slow networks.

## Testing gaps

1. **SSH tunnel integration test skipped** unless Remote Login is enabled.
2. **No real 1Password/Bitwarden tests.** Mocks only.
3. **No GUI tests.** Manual for v1.
4. **No idle timeout integration test.**
5. **No large output test.**
