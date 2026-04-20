# Sneek

macOS menubar app + CLI daemon for managing custom commands with secret resolution, SSH tunnels, and Claude Code MCP integration.

## Why

Managing connections to production infrastructure (databases, APIs, internal services) means juggling passwords, SSH keys, tunnel configs, and connection strings. They end up in plaintext config files, shell history, or environment variables.

Sneek keeps secrets out of config: define a command (like `pg-prod`) in the GUI, point it at a Keychain / 1Password / Bitwarden entry, and Sneek resolves the secret at runtime — never on disk, never in the command string. The same command becomes:

- a one-tap entry in the menubar,
- a generated shell script,
- and an MCP tool that Claude Code can call directly.

The original use case: give Claude Code access to a production Postgres without putting the password, host, or SSH tunnel options in the conversation or any file Claude can read.

## Install

Requires macOS, Swift 6, and full Xcode (not just CommandLineTools).

```bash
git clone git@github.com:biswaz/sneek.git
cd sneek
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release --product sneekd --product Sneek
cp .build/arm64-apple-macosx/release/sneekd /usr/local/bin/sneekd
codesign --force --sign - /usr/local/bin/sneekd
```

Wire up Claude Code:

```bash
sneekd install-mcp        # adds sneek to ~/.claude/settings.json
# or:
claude mcp add sneek -- sneekd mcp-serve
```

## Run

```bash
swift run Sneek           # launches GUI; auto-starts the daemon
```

That's it — one command. The menubar pill (green Running / gray Stopped / orange Error) is also a click toggle for the daemon.

For headless use (no GUI), the CLI is independent:

```bash
sneekd start              # foreground daemon
sneekd run pg-prod "select 1"
sneekd tunnel pg-prod up
sneekd list
```

## Example command

`~/.config/sneek/commands/pg-prod.json`:

```json
{
  "name": "pg-prod",
  "description": "Production Postgres via bastion",
  "tags": ["prod"],
  "mode": "session",
  "readonly": true,
  "command": "psql --csv postgresql://{{user}}:{{password}}@localhost:{{local_port}}/{{database}}",
  "secrets": {
    "password": { "provider": "keychain", "key": "db-prod" }
  },
  "variables": { "user": "app", "database": "myapp_prod" },
  "tunnel": {
    "host": "bastion.example.com",
    "user": "deploy",
    "identity_key": "~/.ssh/prod_key",
    "local_port": 15432,
    "remote_host": "prod-db.internal",
    "remote_port": 5432
  },
  "setup_commands": ["SET default_transaction_read_only = on;"],
  "blocked_patterns": ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],
  "mcp": { "enabled": true, "tool_name": "pg_prod" }
}
```

Claude Code now sees a `sneek_pg_prod` tool — read-only Postgres, bastion-tunneled, password from Keychain, no secrets in the conversation.

## Architecture

GUI is a config editor only. The `sneekd` daemon owns all runtime: tunnel manager, persistent sessions, secret resolution, MCP stdio server, IPC. The two share `SneekLib` and talk over a Unix socket at `~/.config/sneek/sneekd.sock`. The daemon keeps running after the GUI quits so Claude Code's MCP integration stays available.

## More

- Full design and conventions: [`AGENTS.md`](AGENTS.md)
- Backlog: [`TODO.md`](TODO.md)
- Spec: [`docs/superpowers/specs/2026-04-02-sneek-design.md`](docs/superpowers/specs/2026-04-02-sneek-design.md)
