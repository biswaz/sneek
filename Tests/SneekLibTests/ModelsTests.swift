import Foundation
@testable import SneekLib

func runModelsTests() {
    print("Models:")

    test("Full command config round-trip") {
        let json = """
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
          "setup_commands": ["SET default_transaction_read_only = on;"],
          "blocked_patterns": ["DROP", "DELETE", "UPDATE", "INSERT", "ALTER", "TRUNCATE"],
          "sentinel": "\\\\echo __SNEEK_DONE__",
          "mcp": {
            "enabled": true,
            "tool_name": "pg_prod",
            "tool_description": "Run SQL against production Postgres"
          }
        }
        """

        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(CommandConfig.self, from: data)

        check(config.name == "pg-prod", "name")
        check(config.mode == .session, "mode")
        check(config.readonly == true, "readonly")
        check(config.idleTimeout == 300, "idle_timeout")
        check(config.tags == ["prod", "database"], "tags")
        check(config.variables?["user"] == "app", "variables.user")
        check(config.secrets?["password"] == .keychain(key: "db-prod"), "secrets.password")
        check(config.tunnel?.host == "bastion.example.com", "tunnel.host")
        check(config.tunnel?.localPort == 15432, "tunnel.local_port")
        check(config.tunnel?.autoConnect == false, "tunnel.auto_connect")
        check(config.setupCommands == ["SET default_transaction_read_only = on;"], "setup_commands")
        check(config.blockedPatterns?.count == 6, "blocked_patterns count")
        check(config.mcp?.enabled == true, "mcp.enabled")
        check(config.mcp?.toolName == "pg_prod", "mcp.tool_name")

        // Round-trip
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CommandConfig.self, from: encoded)
        check(config == decoded, "round-trip equality")
    }

    test("All secret providers decode correctly") {
        let providers: [(String, SecretRef)] = [
            (#"{"provider":"keychain","key":"db-prod"}"#, .keychain(key: "db-prod")),
            (#"{"provider":"1password","ref":"op://Vault/Item/pass"}"#, .onePassword(ref: "op://Vault/Item/pass")),
            (#"{"provider":"bitwarden","item":"my-db"}"#, .bitwarden(item: "my-db")),
            (#"{"provider":"env","var":"DB_PASS"}"#, .env(variable: "DB_PASS")),
        ]

        for (json, expected) in providers {
            let data = json.data(using: .utf8)!
            let ref = try JSONDecoder().decode(SecretRef.self, from: data)
            check(ref == expected, "provider: \(json)")
        }
    }

    test("Unknown provider throws") {
        let json = #"{"provider":"vault","path":"/secret"}"#
        let data = json.data(using: .utf8)!
        checkThrows({ try JSONDecoder().decode(SecretRef.self, from: data) }, "unknown provider")
    }

    test("Oneshot mode with minimal fields") {
        let json = #"{"name":"echo-test","description":"test","mode":"oneshot","command":"echo hello"}"#
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(CommandConfig.self, from: data)
        check(config.mode == .oneshot, "mode")
        check(config.tunnel == nil, "tunnel nil")
        check(config.secrets == nil, "secrets nil")
    }
}
