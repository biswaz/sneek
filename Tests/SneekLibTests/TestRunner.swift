import Foundation

// Minimal test harness — no XCTest/Testing framework required
nonisolated(unsafe) var _passed = 0
nonisolated(unsafe) var _failed = 0
nonisolated(unsafe) var _errors: [String] = []

func check(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        _passed += 1
    } else {
        _failed += 1
        let loc = URL(fileURLWithPath: file).lastPathComponent
        _errors.append("  FAIL \(loc):\(line) \(message)")
    }
}

func checkThrows<T>(_ body: () throws -> T, _ message: String = "", file: String = #file, line: Int = #line) {
    do {
        _ = try body()
        _failed += 1
        let loc = URL(fileURLWithPath: file).lastPathComponent
        _errors.append("  FAIL \(loc):\(line) expected throw — \(message)")
    } catch {
        _passed += 1
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        print("  ✓ \(name)")
    } catch {
        _failed += 1
        _errors.append("  FAIL \(name): \(error)")
        print("  ✗ \(name): \(error)")
    }
}

func report() {
    print("\n\(_passed) passed, \(_failed) failed")
    for e in _errors { print(e) }
    if _failed > 0 { exit(1) }
}
