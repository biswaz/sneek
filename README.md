# Sneek

I wanted Claude Code to query my production databases without pasting passwords into the chat. That turned out to be three problems stacked on top of each other:

1. **Secrets in plaintext.** Connection strings with embedded passwords end up in config files, shell history, env vars, or — worst of all — the conversation. None of those are places I want a long-lived prod password to live.
2. **SSH tunnels that keep breaking.** Most of my databases sit behind a bastion. The tunnels die, get killed by network changes, or never came up in the first place. Every other "MCP for Postgres" solution assumed a direct connection.
3. **The auto-tunnel script tax.** The fix for #2 is usually "write a wrapper script that brings the tunnel up, waits for it, then runs the command." I'd written that script three times for three different databases. Three different ways. None reusable.

Sneek is what I wished existed. One config per command (`pg-prod`, `redis-prod`, whatever): the password is a reference to a Keychain / 1Password / Bitwarden entry, the SSH tunnel is described declaratively and the daemon keeps it alive, and the whole thing exposes itself to Claude Code as an MCP tool with a single setup line.

The same command also becomes a menubar entry I can click, and a shell script if I just want to use it from the terminal. But MCP was the goal.

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
