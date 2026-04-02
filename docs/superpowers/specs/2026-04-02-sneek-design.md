# Sneek — Design Spec

## Context

Managing connections to production infrastructure (databases, APIs, internal services) through SSH tunnels requires juggling passwords, SSH keys, tunnel configs, and connection strings. These secrets end up in plaintext config files, shell history, or scattered across environment variables.

Sneek is a macOS app that centralizes this. You define custom commands (like `pg-prod`) in a GUI, configure secrets (pulled from Keychain/1Password/Bitwarden at runtime), optional SSH tunnels, and expose them to Claude Code as MCP tools or to the terminal as shell scripts. Secrets are never stored — only references to secret providers.

## Architecture

**Two binaries:**

- **Sneek.app** — SwiftUI GUI. Menubar icon with detachable window. Creates/edits/deletes command configs. Communicates with daemon via Unix socket IPC.
- **sneekd** — Swift CLI daemon. The runtime brain. Manages SSH tunnels, resolves secrets, maintains persistent CLI sessions, serves MCP protocol, generates shell scripts.

**Config lives in** `~/.config/sneek/`:
```
~/.config/sneek/
├── config.json              # Global settings
├── commands/
│   ├── pg-prod.json         # One file per command
│   ├── redis-cache.json
│   └── api-internal.json
├── sneekd.sock              # Unix socket (daemon ↔ GUI/CLI)
└── logs/
    └── sneekd.log
```

**Communication:**
- GUI ↔ daemon: Unix socket IPC (`~/.config/sneek/sneekd.sock`)
- Claude Code → daemon: stdio MCP protocol (`sneekd mcp-serve`)
- Terminal → daemon: CLI subcommand (`sneekd run <name>`)

## Data Model

A command config (`~/.config/sneek/commands/pg-prod.json`):

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
    "password": {
      "provider": "keychain",
      "key": "db-prod"
    }
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

  "setup_commands": [
    "SET default_transaction_read_only = on;"
  ],
  "blocked_patterns": ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],

  "mcp": {
    "enabled": true,
    "tool_name": "pg_prod",
    "tool_description": "Run SQL against production Postgres"
  }
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique command identifier, used in CLI and shell scripts |
| `description` | yes | Human-readable description |
| `tags` | no | For filtering/scoping commands |
| `mode` | yes | `"session"` (persistent process) or `"oneshot"` (run and exit) |
| `idle_timeout` | no | Seconds before reaping idle session (default 300) |
| `readonly` | no | Marks command as read-only in MCP tool description |
| `command` | yes | Command template with `{{variable}}` interpolation |
| `secrets` | no | Map of variable name → secret provider reference |
| `variables` | no | Map of variable name → plain value |
| `tunnel` | no | SSH tunnel configuration |
| `setup_commands` | no | Commands run once at session start (e.g., `SET default_transaction_read_only = on;`) |
| `blocked_patterns` | no | Daemon rejects input containing these strings when `readonly: true` |
| `mcp` | no | MCP exposure settings |

### Secret Providers

| Provider | Config | Resolved via |
|----------|--------|-------------|
| `keychain` | `{"provider": "keychain", "key": "db-prod"}` | `security find-internet-password -s "key" -w` |
| `1password` | `{"provider": "1password", "ref": "op://Vault/Item/field"}` | `op read "ref"` |
| `bitwarden` | `{"provider": "bitwarden", "item": "item-name"}` | `bw get password "item"` |
| `env` | `{"provider": "env", "var": "MY_PASSWORD"}` | `$MY_PASSWORD` |

## Connection Persistence

Commands with `"mode": "session"` keep a persistent subprocess alive:

1. First invocation → daemon spawns the process (e.g., `psql --csv --quiet ...`)
2. Runs `setup_commands` (e.g., `SET default_transaction_read_only = on;`)
3. Sends user input to stdin, appends a sentinel command to mark end of output
4. Reads stdout until sentinel line
5. Returns output, keeps process alive
6. Idle for `idle_timeout` seconds → reap process
7. Next invocation → re-spawn

The sentinel command is configurable per command via a `sentinel` field (defaults provided for known types):
- Postgres: `\echo __SNEEK_DONE__`
- MySQL: `SELECT '__SNEEK_DONE__';`
- Redis: `ECHO __SNEEK_DONE__`
- Generic: configurable, or fall back to oneshot mode

Commands with `"mode": "oneshot"` spawn a new process per invocation.

## Read-Only Mode

Two layers of protection when `readonly: true`:

1. **Setup commands** — run at session start. The database/service itself enforces read-only (e.g., Postgres rejects writes at the transaction level).
2. **Blocked patterns** — daemon rejects input matching patterns before it reaches the session. Safety net, not a guarantee (regex can't parse SQL).

The GUI auto-fills setup commands and blocked patterns for known types (Postgres, MySQL, Redis) when read-only is toggled on.

## SSH Tunnel Management

The daemon manages tunnel lifecycles:

- **Auto-connect tunnels** (`auto_connect: true`) start when daemon starts
- **On-demand tunnels** start on first command invocation
- **Health monitoring** — daemon checks tunnel liveness periodically
- **Auto-reconnect** — exponential backoff on failure, GUI status updates
- **Graceful shutdown** — all tunnels torn down when daemon stops

Tunnels are shared — if `pg-prod` and `pg-staging` use the same bastion with different local/remote ports, both tunnels are managed independently.

## GUI

### Menubar Popover
- Daemon status indicator (running/stopped)
- Search bar
- Command list with tunnel status (green/red dot) and MCP badge
- "+ New Command" and "Open Window" actions

### Detached Window
- Sidebar: command list with selection
- Editor pane with sections:
  - **General** — name, description, tags, mode (session/oneshot)
  - **Command Template** — with highlighted `{{variables}}`
  - **Variables & Secrets** — side by side, secrets show provider + key
  - **Access Control** — read-only toggle, setup commands, blocked patterns
  - **SSH Tunnel** — bastion host, SSH user, identity key, local/remote port mapping
  - **MCP Integration** — enable toggle, tool name, tool description

## Claude Code Integration

### One-time setup
The app adds a single MCP server entry to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "sneek": {
      "command": "/usr/local/bin/sneekd",
      "args": ["mcp-serve"]
    }
  }
}
```

All MCP-enabled commands appear as Claude tools automatically.

### Per-project scoping
Override in a project's `.claude/settings.json`:
```json
{
  "mcpServers": {
    "sneek": {
      "command": "sneekd",
      "args": ["mcp-serve", "--tags", "prod,database"]
    }
  }
}
```
Or: `"args": ["mcp-serve", "--commands", "pg-prod,redis-cache"]`

### MCP tool shape
Each enabled command becomes a tool:
```json
{
  "name": "sneek_pg_prod",
  "description": "Run SQL against production Postgres [read-only]",
  "inputSchema": {
    "type": "object",
    "properties": {
      "input": { "type": "string", "description": "SQL query or command to execute" }
    },
    "required": ["input"]
  }
}
```

### Shell scripts
Generated to a configurable directory (default `~/bin/`):
```bash
#!/bin/bash
# ~/bin/pg-prod — generated by Sneek (do not edit)
exec sneekd run pg-prod "$@"
```

`sneekd run pg-prod` → interactive session. `sneekd run pg-prod "SELECT 1"` → one-shot query.

## Daemon CLI

```
sneekd start                         # Start daemon
sneekd stop                          # Graceful shutdown
sneekd status                        # Show status, tunnels, sessions

sneekd mcp-serve                     # Stdio MCP server (launched by Claude)
  --tags prod,db                     # Filter by tags
  --commands pg-prod                 # Filter by name

sneekd run <name> [input]            # Run a command
sneekd tunnel <name> up|down|status  # Manage tunnels directly
sneekd list                          # List all commands
sneekd generate-scripts              # Regenerate shell scripts
sneekd install-mcp                   # Add sneek to Claude MCP config
```

## Tech Stack

- **Language:** Swift (both app and daemon)
- **GUI:** SwiftUI, menubar app with `MenuBarExtra` + detachable `Window`
- **Build:** Swift Package Manager for daemon, Xcode for app
- **IPC:** Unix domain socket with JSON messages
- **MCP:** stdio JSON-RPC (Model Context Protocol)
- **SSH tunnels:** spawned via `ssh -fN -L ...`, monitored by daemon
- **Keychain:** Security framework (`SecItemCopyMatching`) for native access

## Testing Strategy

### Unit Tests (pure logic, no external dependencies)
- Config JSON parsing and validation
- `{{variable}}` template interpolation
- Blocked pattern matching against input
- Sentinel output parsing (detect end-of-output markers)
- MCP JSON-RPC message serialization/deserialization
- Command config field defaults and merging

### Integration Tests (local setup, real processes)
- **Session manager** — spawn a real `cat` or `bc` process, verify stdin/stdout/sentinel flow, idle timeout reaping
- **Secret resolver** — test Keychain via a test entry (`security add-generic-password` in test setup, clean up in teardown). 1Password/Bitwarden stubbed behind `SecretProvider` protocol.
- **Tunnel manager** — test against `localhost` SSH (`ssh localhost -L ...`). Verify tunnel comes up, health check passes, auto-reconnect on kill.
- **MCP protocol** — pipe stdin/stdout to `sneekd mcp-serve`, send JSON-RPC tool list and tool call messages, assert correct responses.
- **IPC** — spin up daemon, connect via Unix socket, send status/tunnel/run commands, verify responses.
- **Shell scripts** — generate scripts, execute them, verify they delegate to `sneekd run` correctly.

### Protocol Abstractions (for testability)
Key daemon components sit behind Swift `protocol`s:
- `SecretProvider` — `resolve(key:) -> String`. Real: Keychain, 1Password, Bitwarden, Env. Test: in-memory dictionary.
- `TunnelManager` — `ensureUp(tunnel:)`, `tearDown(tunnel:)`, `status(tunnel:)`. Real: SSH process. Test: mock that tracks state.
- `SessionManager` — `send(input:to:) -> String`, `reap(name:)`. Real: subprocess. Test: `cat` process with echo sentinel.

### Manual Testing (v1)
- GUI interactions (SwiftUI UI tests are fragile — manual for v1)
- Real remote SSH tunnels through bastion hosts
- Real 1Password/Bitwarden CLI integration (requires auth sessions)

## Verification

1. **Build and launch** — `sneekd start` runs without errors, creates socket file
2. **Create command via GUI** — JSON file appears in `~/.config/sneek/commands/`
3. **Tunnel management** — `sneekd tunnel pg-prod up` establishes SSH tunnel, `status` shows it active
4. **Session persistence** — `sneekd run pg-prod "SELECT 1"` works, second invocation reuses session (no reconnect delay)
5. **Read-only enforcement** — `sneekd run pg-prod "DROP TABLE x"` rejected by blocked patterns and by setup command enforcement
6. **Secret resolution** — store a test password in Keychain, verify daemon retrieves it
7. **MCP integration** — `sneekd install-mcp`, start Claude Code, verify `sneek_pg_prod` tool appears and executes queries
8. **Shell scripts** — `sneekd generate-scripts`, run `~/bin/pg-prod "SELECT 1"` from terminal
9. **GUI status** — menubar shows tunnel status, daemon status updates live
