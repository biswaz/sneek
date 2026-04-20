# GUI Auto-Starts the Daemon

**Date:** 2026-04-20
**Status:** Approved
**Scope:** `Sources/SneekApp/AppState.swift`, `Sources/SneekApp/MenuBarView.swift`

## Problem

Currently the user must run two commands to use Sneek in dev:

```
swift run sneekd start
swift run Sneek
```

The GUI ships with a manual start/stop toggle in the menubar (`AppState.startDaemon()`), but it (a) doesn't auto-run on launch, and (b) hardcodes `/usr/bin/env sneekd`, which fails in dev where `sneekd` is not on `PATH`.

Additionally, the existing toggle looks like plain text with a colored dot. Users don't realize it's clickable.

## Goal

Launching Sneek should be one command — `swift run Sneek` (or opening the installed `.app`) — and the daemon should be running by the time the menubar opens. The status indicator should clearly look like a button/toggle while still communicating state.

## Design

### 1. Locate `sneekd` in dev and prod

Add a private helper to `AppState`:

```swift
private func locateSneekd() -> String? {
    let candidates: [String] = [
        // 1. Sibling to the Sneek executable.
        //    Dev:        .build/arm64-apple-macosx/debug/{Sneek,sneekd}
        //    .app bundle: Sneek.app/Contents/MacOS/{Sneek,sneekd}
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("sneekd").path,
        // 2. Standard install location (per CLAUDE.md).
        "/usr/local/bin/sneekd",
        // 3. Homebrew on Apple Silicon.
        "/opt/homebrew/bin/sneekd",
    ].compactMap { $0 }

    if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return hit
    }

    // 4. Last resort: PATH lookup via /usr/bin/which.
    return whichSneekd()
}
```

`whichSneekd()` runs `/usr/bin/which sneekd` and returns the trimmed stdout if exit code is 0, else nil.

### 2. Use the resolved path in `startDaemon()`

Replace the current `/usr/bin/env sneekd` invocation with the resolved absolute path. If `locateSneekd()` returns nil, set `daemonError` (see below) and bail without spawning.

### 3. Auto-start on launch

In `AppState.init()`, after the existing `refreshStatus()` call:

```swift
if !daemonRunning {
    startDaemon()
}
```

`refreshStatus()` is synchronous (IPC `send` is blocking with a timeout), so by the time we read `daemonRunning` we have a definitive answer. No race.

`startDaemon()` already has a 1-second deferred `refreshStatus()`, so the menubar dot turns green shortly after launch.

### 4. Daemon lifecycle on quit

Do **not** kill the daemon when the GUI quits. This matches the architecture decision in `CLAUDE.md`: "the daemon runs without the GUI open." A user who quits the app still wants Claude Code's MCP integration to work. They stop the daemon explicitly via the menubar toggle or `sneekd stop`.

### 5. Error surface

Add to `AppState`:

```swift
@Published var daemonError: String? = nil
```

Set it when:
- `locateSneekd()` returns nil → `"sneekd binary not found. Build with: swift build"`
- `Process.run()` throws → `"Failed to start sneekd: \(error.localizedDescription)"`

Cleared when `refreshStatus()` succeeds with `daemonRunning == true`.

### 6. Status toggle styling

Replace the current button label in `MenuBarView`:

```swift
Button {
    if appState.daemonRunning { appState.stopDaemon() }
    else { appState.startDaemon() }
} label: {
    HStack(spacing: 6) {
        Circle().fill(stateColor).frame(width: 7, height: 7)
        Text(stateLabel).font(.caption).fontWeight(.medium)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(stateColor.opacity(0.15)))
    .overlay(Capsule().strokeBorder(stateColor.opacity(0.4), lineWidth: 1))
}
.buttonStyle(.plain)
.help(tooltipText)
```

State derivation (computed in the view, reading `appState`):

| Condition | `stateColor` | `stateLabel` | `tooltipText` |
|---|---|---|---|
| `daemonError != nil` | `.orange` | `"Error"` | the error message |
| `daemonRunning` | `.green` | `"Running"` | `"Click to stop daemon"` |
| else | `.secondary` | `"Stopped"` | `"Click to start daemon"` |

Error takes precedence — a stale "running" with an error is more confusing than a clear "Error" badge.

### 7. Logging

Add a tiny `AppLog` helper in `AppState.swift`:

```swift
enum AppLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/sneek/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sneek-app.log")
    }()

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
```

Lines emitted (replace existing `print(...)` calls in `AppState`):

| When | Message |
|---|---|
| `locateSneekd()` resolves | `"sneekd resolved at: <path>"` |
| `locateSneekd()` returns nil | `"sneekd not found. Searched: <candidates>"` |
| `startDaemon()` spawns | `"starting daemon: <path>"` |
| `startDaemon()` Process.run throws | `"failed to start daemon: <error>"` |
| `stopDaemon()` called | `"stopping daemon"` |
| `loadConfig` / `save` / `delete` errors | `"<op> failed: <error>"` (replace existing `print`s) |

Tail with:
```
tail -f ~/.config/sneek/logs/sneek-app.log
```

When running via `swift run Sneek`, the same lines also appear on stderr in the terminal.

## What's deliberately out of scope

- Bundling `sneekd` inside an `.app` bundle. The lookup supports it for free, but no packaging script is added.
- Killing the daemon when the GUI quits.
- Auto-restart on daemon crash.
- A separate "daemon settings" pane.

## Files touched

- `Sources/SneekApp/AppState.swift` — add `locateSneekd()`, `whichSneekd()`, `daemonError`, `AppLog`; modify `startDaemon()`, `init()`, `refreshStatus()`; replace existing `print` calls with `AppLog.log`.
- `Sources/SneekApp/MenuBarView.swift` — restyle the status button; add state-derivation locals.

No changes to `SneekLib`, daemon, tests, or config schema.

## Verification

1. `swift build` — compiles cleanly.
2. `pkill sneekd; swift run Sneek` — menubar opens with green "Running" pill within ~1s.
3. Click the pill — daemon stops, pill turns gray "Stopped".
4. Click again — daemon starts, pill turns green.
5. Move/rename `sneekd` in the build dir, relaunch — pill shows orange "Error" with the binary-not-found message in the tooltip.
6. `tail -f ~/.config/sneek/logs/sneek-app.log` while doing the above — see `sneekd resolved at:`, `starting daemon:`, `stopping daemon`, and (in step 5) `sneekd not found. Searched: ...` lines.
7. `swift run SneekTests` — still 136/136 passing (no library changes).
