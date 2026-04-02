# Sneek

macOS app + CLI daemon for managing custom commands with secret resolution, SSH tunnels, and Claude Code MCP integration.

## Architecture

Two binaries + shared library:

- **Sneek.app** (`Sources/SneekApp/`) — SwiftUI menubar app with detachable window. Config editor only, no runtime logic.
- **sneekd** (`Sources/sneekd/`) — CLI daemon. All runtime: tunnels, secrets, sessions, MCP server, IPC.
- **SneekLib** (`Sources/SneekLib/`) — Shared library used by both.

## Project Structure

```
Sources/
  SneekLib/              # Core library
    Models.swift         # CommandConfig, SecretRef, TunnelConfig, MCPConfig, SneekConfig
    ConfigStore.swift    # JSON config loading/saving from ~/.config/sneek/
    SecretResolver.swift # SecretProvider protocol + Keychain/1Password/Bitwarden/Env
    TemplateEngine.swift # {{variable}} interpolation
    TunnelManager.swift  # SSH tunnel spawn/health check/teardown (actor)
    SessionManager.swift # Persistent subprocess sessions with sentinel parsing (actor)
    IPCProtocol.swift    # Unix domain socket IPC client/server
    MCPServer.swift      # stdio JSON-RPC MCP server for Claude Code
    ScriptGenerator.swift # Shell script + Claude MCP config generation
    Daemon.swift         # Orchestrates all components, handles IPC requests
  sneekd/
    Sneekd.swift         # CLI entry point (swift-argument-parser subcommands)
  SneekApp/
    SneekApp.swift       # App entry point (menubar + window scenes)
    AppState.swift       # Observable state, config loading, daemon status
    MenuBarView.swift    # Menubar popover (search, command list, badges)
    CommandEditorView.swift # Full command editor form
Tests/
  SneekLibTests/         # 100 checks across 40 tests (custom test runner, no XCTest)
```

## Key Design Decisions

- **Secrets are never stored.** Config only holds provider references (e.g., `{"provider": "keychain", "key": "db-prod"}`). Resolved at runtime by the daemon.
- **Persistent sessions.** Commands with `mode: "session"` keep a subprocess alive. A configurable sentinel command marks end-of-output.
- **Read-only mode.** Two layers: setup commands (e.g., `SET default_transaction_read_only = on;`) and blocked pattern matching before input reaches the session.
- **MCP integration.** `sneekd mcp-serve` is a stdio JSON-RPC server. One MCP server entry in Claude's config serves all commands. Per-project scoping via `--tags` or `--commands` flags.
- **Config format.** One JSON file per command in `~/.config/sneek/commands/`. See `docs/superpowers/specs/2026-04-02-sneek-design.md` for the full schema.

## Build & Test

```bash
# Requires Xcode (not just CommandLineTools) for SwiftUI
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build              # Build all targets
swift run SneekTests     # Run tests (custom runner, not swift test)
swift run sneekd --help  # CLI help
swift run Sneek          # Launch GUI
```

## Config Location

`~/.config/sneek/` — commands, global config, daemon socket, logs.

## Spec

Full design spec with data model, architecture, testing strategy: `docs/superpowers/specs/2026-04-02-sneek-design.md`
