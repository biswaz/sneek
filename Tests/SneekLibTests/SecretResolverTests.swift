import Foundation
@testable import SneekLib

/// A mock provider that returns values from an in-memory dictionary.
struct InMemoryProvider: SecretProvider {
    let store: [String: String]

    func resolve(_ key: String) async throws -> String {
        guard let value = store[key] else {
            throw SecretResolutionError.envNotFound(variable: key)
        }
        return value
    }
}

func runSecretResolverTests() {
    print("\nSecretResolver:")

    test("EnvProvider resolves from environment") {
        let provider = EnvProvider()
        // PATH is always set
        let value = try blockingAsync { try await provider.resolve("PATH") }
        check(!value.isEmpty, "PATH should be non-empty")
    }

    test("EnvProvider throws for missing variable") {
        let provider = EnvProvider()
        checkThrows({
            try blockingAsync { try await provider.resolve("SNEEK_TEST_NONEXISTENT_VAR_\(UUID().uuidString)") }
        }, "should throw for missing env var")
    }

    test("SecretResolver merges secrets and variables") {
        let mockProvider = InMemoryProvider(store: ["DB_PASS": "s3cret"])
        let resolver = SecretResolver(
            secrets: ["password": .env(variable: "DB_PASS")],
            variables: ["host": "localhost", "port": "5432"],
            envProvider: mockProvider
        )

        let result = try blockingAsync { try await resolver.resolveAll() }
        check(result["password"] == "s3cret", "secret resolved")
        check(result["host"] == "localhost", "variable preserved")
        check(result["port"] == "5432", "variable preserved")
        check(result.count == 3, "exactly 3 entries")
    }

    test("SecretResolver with InMemoryProvider for all provider types") {
        let mock = InMemoryProvider(store: [
            "db-prod": "keychain-pass",
            "op://Vault/Item/pass": "op-pass",
            "my-db": "bw-pass",
            "API_KEY": "env-pass",
        ])

        let resolver = SecretResolver(
            secrets: [
                "kc_secret": .keychain(key: "db-prod"),
                "op_secret": .onePassword(ref: "op://Vault/Item/pass"),
                "bw_secret": .bitwarden(item: "my-db"),
                "env_secret": .env(variable: "API_KEY"),
            ],
            variables: ["static": "value"],
            keychainProvider: mock,
            onePasswordProvider: mock,
            bitwardenProvider: mock,
            envProvider: mock
        )

        let result = try blockingAsync { try await resolver.resolveAll() }
        check(result["kc_secret"] == "keychain-pass", "keychain resolved")
        check(result["op_secret"] == "op-pass", "1password resolved")
        check(result["bw_secret"] == "bw-pass", "bitwarden resolved")
        check(result["env_secret"] == "env-pass", "env resolved")
        check(result["static"] == "value", "plain variable kept")
        check(result.count == 5, "5 total entries")
    }

    test("SecretResolver secret overrides variable with same name") {
        let mock = InMemoryProvider(store: ["MY_KEY": "from-secret"])
        let resolver = SecretResolver(
            secrets: ["shared": .env(variable: "MY_KEY")],
            variables: ["shared": "from-variable"],
            envProvider: mock
        )

        let result = try blockingAsync { try await resolver.resolveAll() }
        check(result["shared"] == "from-secret", "secret takes precedence over variable")
    }

    test("SecretResolver with empty secrets") {
        let resolver = SecretResolver(secrets: [:], variables: ["a": "1"])
        let result = try blockingAsync { try await resolver.resolveAll() }
        check(result == ["a": "1"], "just variables")
    }
}

// Bridge async calls into the synchronous test harness.
private func blockingAsync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do {
            let value = try await body()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result!.get()
}
