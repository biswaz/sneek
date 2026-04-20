# Sneek

macOS app + CLI daemon for managing custom commands with secret resolution, SSH tunnels, and Claude Code MCP integration.

## Why This Exists

Managing connections to production infrastructure (databases, APIs, internal services) requires juggling passwords, SSH keys, tunnel configs, and connection strings. These secrets end up in plaintext config files, shell history, or environment variables.

Sneek solves this: define custom commands (like `pg-prod`) in a GUI, configure secrets (pulled from Keychain/1Password/Bitwarden at runtime — never stored), optional SSH tunnels, and expose them to Claude Code as MCP tools or to the terminal as shell scripts.

The core requirement: **give Claude Code access to prod databases without exposing secrets** (passwords, IPs, SSH tunnel options) in the conversation or config files.

## Architecture

**GUI + CLI Daemon** pattern (chosen over monolith or generated-scripts-only):
- The daemon runs without the GUI open — Claude Code can use commands even when the app isn't visible
- The GUI is just a config editor — no runtime logic
- Both share `SneekLib`

```
┌──────────────┐     ┌─────────────────────────────────────────┐     ┌──────────────┐
│  Sneek.app   │     │              sneekd                     │     │  Claude Code  │
│  (SwiftUI)   │────▶│  Tunnel Manager  │  Session Manager     │◀────│  (MCP stdio)  │
│  config only │ IPC │  Secret Resolver │  MCP Server          │     │              │
└──────────────┘     │  Script Generator│  IPC Server           │     └──────────────┘
                     └─────────────────────────────────────────┘
                              ▲                                        ┌──────────────┐
                              │ IPC                                    │   Terminal    │
                              └────────────────────────────────────────│ sneekd run   │
                                                                      └──────────────┘
```

**Why this over alternatives:**
- **Not a monolith** — daemon can run headless, MCP server doesn't need the GUI
- **Not generated scripts only** — persistent sessions need a long-running process; tunnel health monitoring needs a daemon
- **Not native DB drivers** — chose persistent CLI sessions (generic, works with any tool) over native drivers (would need per-DB Swift drivers, not generic)

## Project Structure

```
Sources/
  SneekLib/                  # Core library (shared by app and daemon)
    Models.swift             # CommandConfig, SecretRef, TunnelConfig, MCPConfig, SneekConfig
    ConfigStore.swift        # JSON config loading/saving from ~/.config/sneek/
    SecretResolver.swift     # SecretProvider protocol + Keychain/1Password/Bitwarden/Env
    TemplateEngine.swift     # {{variable}} interpolation
    TunnelManager.swift      # SSH tunnel spawn/health check/teardown (actor)
    SessionManager.swift     # Persistent subprocess sessions with sentinel parsing (actor)
    IPCProtocol.swift        # Unix domain socket IPC client/server
    MCPServer.swift          # stdio JSON-RPC MCP server for Claude Code
    ScriptGenerator.swift    # Shell script + Claude MCP config generation
    Daemon.swift             # Orchestrates all components, handles IPC requests
  sneekd/
    Sneekd.swift             # CLI entry point (swift-argument-parser subcommands)
  SneekApp/
    SneekApp.swift           # App entry point (menubar + window scenes)
    AppState.swift           # Observable state, config loading, daemon status
    MenuBarView.swift        # Menubar popover (search, command list, badges)
    CommandEditorView.swift  # Full command editor form
Tests/
  SneekLibTests/             # 136 checks across 49 tests
    TestRunner.swift         # Custom test harness (no XCTest — see note below)
    Main.swift               # Test entry point
    ModelsTests.swift        # JSON round-trip, all secret providers, edge cases
    ConfigStoreTests.swift   # Load, save, delete, reload, global config
    SecretResolverTests.swift # Real env, mock providers, merge logic
    TemplateEngineTests.swift # Substitution, missing vars, edge cases
    TunnelManagerTests.swift  # Mock tunnel lifecycle
    SessionManagerTests.swift # Oneshot, blocked patterns
    MCPServerTests.swift      # JSON-RPC protocol, tool list, filtering
    ScriptGeneratorTests.swift # Script content, permissions, install-mcp
    IntegrationTests.swift    # Real stack: keychain, sessions, read-only, MCP
docs/
  superpowers/specs/
    2026-04-02-sneek-design.md  # Full design spec
```

## Build & Test

```bash
# REQUIRED: Xcode must be installed (not just CommandLineTools)
# SwiftUI and the test runner need the full Xcode SDK
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build              # Build all 3 targets (sneekd, Sneek, SneekTests)
swift run SneekTests     # Run tests (custom runner — NOT swift test)
swift run sneekd --help  # CLI help
swift run Sneek          # Launch GUI (menubar + dock)
```

**Why not `swift test`?** The project uses a custom executable test runner (`SneekTests` target) instead of XCTest because the CommandLineTools-only Swift toolchain doesn't include XCTest or Swift Testing. The test target is an `.executableTarget` in Package.swift, not a `.testTarget`. Tests use `check()` / `test()` / `report()` from `TestRunner.swift`.

**To install binaries:**
```bash
swift build -c release --product sneekd --product Sneek && cp .build/arm64-apple-macosx/release/sneekd /usr/local/bin/sneekd && codesign --force --sign - /usr/local/bin/sneekd
```

## Config

All config lives in `~/.config/sneek/`:
```
~/.config/sneek/
├── config.json              # Global settings (script_output_dir, log_level)
├── commands/
│   ├── pg-prod.json         # One JSON file per command
│   └── echo-demo.json
├── sneekd.sock              # Unix socket (daemon ↔ clients)
└── logs/
    └── sneekd.log
```

## Key Design Decisions

### Secrets are never stored
Config holds only provider references. Resolved at runtime by the daemon.
```json
"secrets": { "password": { "provider": "keychain", "key": "db-prod" } }
```
Supported providers: macOS Keychain (`find-generic-password`, falls back to `find-internet-password`), 1Password (`op read`), Bitwarden (`bw get password`), environment variables.

### Persistent sessions over native drivers
Commands with `mode: "session"` keep a subprocess alive (like an open psql connection). A **sentinel command** marks end-of-output — the daemon sends the sentinel after each user input and reads stdout until `__SNEEK_DONE__` appears.

**Critical implementation detail:** The sentinel detection matches the *output* of the sentinel command (`__SNEEK_DONE__`), not the command itself (`echo __SNEEK_DONE__`). This was a bug that was caught and fixed during integration testing.

Default sentinels per known type:
- Postgres: `\echo __SNEEK_DONE__`
- MySQL: `SELECT '__SNEEK_DONE__';`
- Redis: `ECHO __SNEEK_DONE__`
- Generic/bash: `echo __SNEEK_DONE__`

Custom sentinel via the `sentinel` field in command config.

### Read-only mode — two layers
1. **Setup commands** — run at session start (e.g., `SET default_transaction_read_only = on;`). The database itself enforces read-only.
2. **Blocked patterns** — daemon rejects input containing patterns (DROP, DELETE, etc.) *before* it reaches the session. Case-insensitive. Safety net, not a guarantee.

### One MCP server for all commands
`sneekd mcp-serve` is a single stdio JSON-RPC process. Claude's config points to it once. All MCP-enabled commands appear as tools. Per-project scoping via `--tags` or `--commands` flags.

### GUI is a config editor only
The SwiftUI app (menubar + detachable window) reads/writes JSON config files. It does not run commands, manage tunnels, or serve MCP. All runtime is in the daemon.

The app shows in the Dock (`NSApplication.shared.setActivationPolicy(.regular)`) and activates properly when "Open Window" is clicked (`NSApplication.shared.activate(ignoringOtherApps: true)`).

### AppState is the shared source of truth for both GUI views
`SneekApp` owns a single `@StateObject AppState`, passed via `.environmentObject` to both `MenuBarView` (menubar popover) and `CommandEditorView` (main window). Both views read `appState.filteredCommands` — there is no second AppState instance. If a GUI bug shows different data in the two views, the cause is rendering/layout, not state divergence.

AppState is a **snapshot cache**, not live state: `loadConfig()` runs only on app-activation events (`MenuBarView.onAppear`, window `didBecomeActiveNotification`). It constructs a fresh `ConfigStore` each call and does not wire up `onChange` or call `startWatching()`. External JSON edits won't appear in the GUI until the app is re-activated. The daemon keeps its own watched `ConfigStore` — a separate cache.

## What Works

- Config CRUD (create, save, delete, reload with file watching)
- Secret resolution from real macOS Keychain (tested in integration tests)
- Template interpolation with `{{variable}}` syntax
- Persistent sessions with sentinel-based output parsing
- Setup commands at session start
- Read-only enforcement (blocked patterns + setup commands)
- SSH tunnel spawn, health check (TCP connect), teardown
- MCP stdio server (initialize, tools/list, tools/call)
- Per-project MCP scoping (tags, command names)
- Shell script generation with correct permissions
- Claude Code config installation (`install-mcp`)
- Full CLI with all subcommands
- GUI with menubar popover + detachable editor window

## Backlog

See [`TODO.md`](TODO.md).

## Testing

136 checks, 0 failures. Run via `swift run SneekTests`.

**Unit tests** (no external dependencies):
- Models: JSON round-trip, all 4 secret providers, unknown provider throws, minimal config
- ConfigStore: load, save, delete, reload, global config
- TemplateEngine: substitution, multiple vars, missing var throws, edge cases
- MCP: JSON-RPC protocol, tool list filtering (enabled/disabled/tags/commands)
- ScriptGenerator: content, permissions, install-mcp create/preserve

**Integration tests** (real stack, no mocks):
- **Real Keychain**: stores a password via `security add-generic-password`, resolves via `KeychainProvider`, cleans up
- **Persistent bash session**: sends multiple commands to a live bash process, verifies output, confirms session reuse
- **Setup commands**: sets env vars at session start, verifies they persist for subsequent commands
- **Read-only enforcement**: 6 dangerous SQL patterns blocked (DROP, DELETE, UPDATE, INSERT, ALTER, TRUNCATE), 5 safe queries allowed (SELECT, SHOW, EXPLAIN, \dt)
- **Full pipeline**: Keychain secret → SecretResolver → TemplateEngine → SessionManager → output verified
- **SSH tunnel**: localhost port forward, TCP health check, teardown (skipped if Remote Login disabled)
- **MCP tools/call**: real command execution via JSON-RPC handleMessage
- **Script generation**: verifies shebang, exec delegation, 755 permissions
- **Daemon handler**: full resolve → render → execute pipeline

All integration tests have a 10-second timeout to prevent hangs. Cleanup uses 3-second timeouts.

## CLI Reference

```
sneekd start                              # Start daemon (foreground, blocks)
sneekd stop                               # Stop daemon via IPC
sneekd status                             # Show daemon/tunnel/session status

sneekd run <name> [input]                 # Execute a command
sneekd tunnel <name> up|down|status       # Manage tunnels

sneekd list                               # List all configured commands
sneekd mcp-serve [--tags x] [--commands y] # Run as MCP stdio server
sneekd generate-scripts [--output-dir p]  # Generate shell wrapper scripts
sneekd install-mcp                        # Add sneek to Claude MCP config
```

## MCP Integration

One-time setup via CLI:
```bash
claude mcp add sneek -- sneekd mcp-serve
```

Or programmatically: `sneekd install-mcp` adds to `~/.claude/settings.json`:
```json
{ "mcpServers": { "sneek": { "command": "sneekd", "args": ["mcp-serve"] } } }
```

Per-project override in `.claude/settings.json`:
```json
{ "mcpServers": { "sneek": { "command": "sneekd", "args": ["mcp-serve", "--tags", "prod"] } } }
```

Each MCP-enabled command becomes a tool named `sneek_<tool_name>` with a single `input` string parameter. Read-only commands get `[read-only]` appended to the description.

## Command Config Schema

```json
{
  "name": "pg-prod",
  "description": "Production Postgres via bastion",
  "tags": ["prod", "database"],
  "mode": "session",
  "idle_timeout": 300,
  "readonly": true,
  "command": "psql --csv --quiet postgresql://{{user}}:{{password}}@localhost:{{local_port}}/{{database}}",
  "secrets": {
    "password": { "provider": "keychain", "key": "db-prod" }
  },
  "variables": {
    "user": "app",
    "database": "myapp_prod"
  },
  "tunnel": {
    "host": "bastion.example.com",
    "user": "deploy",
    "identity_key": "~/.ssh/prod_key",
    "local_port": 15432,
    "remote_host": "prod-db.internal",
    "remote_port": 5432,
    "auto_connect": false
  },
  "setup_commands": ["SET default_transaction_read_only = on;"],
  "blocked_patterns": ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],
  "sentinel": "\\echo __SNEEK_DONE__",
  "mcp": {
    "enabled": true,
    "tool_name": "pg_prod",
    "tool_description": "Run SQL against production Postgres"
  }
}
```

## Concurrency Model

Swift 6 strict concurrency. Key actors:
- `SessionManager` — actor. Owns all live sessions (process handles, stdin/stdout pipes). Idle timer uses `WeakRef` wrapper to avoid `self` capture issues in `DispatchSource` closures.
- `SSHTunnelManager` — actor. Owns all SSH tunnel processes. Protocol methods are `async` (required by Swift 6 — actor-isolated methods can't satisfy sync protocol requirements).
- `ConfigStore` — `@unchecked Sendable` class (immutable after init in practice, but has mutable `commands` dict for reload).
- `MCPServer` — `@unchecked Sendable` class (all stored properties are set once in init).
- `SecretResolver` — `@unchecked Sendable` class (all stored properties are `let`).
- All model structs and enums conform to `Sendable`.

## Spec

Full design spec: `docs/superpowers/specs/2026-04-02-sneek-design.md`
