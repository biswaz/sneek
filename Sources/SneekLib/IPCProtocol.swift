import Foundation

// MARK: - IPC Message Types

public enum IPCAction: String, Codable, Sendable {
    case status
    case run
    case tunnel
    case list
    case shutdown
}

public struct IPCRequest: Codable, Sendable {
    public var action: IPCAction
    public var command: String?
    public var input: String?
    public var operation: String?  // for tunnel: "up", "down", "status"

    public init(action: IPCAction, command: String? = nil, input: String? = nil, operation: String? = nil) {
        self.action = action
        self.command = command
        self.input = input
        self.operation = operation
    }
}

public struct IPCResponse: Codable, Sendable {
    public var success: Bool
    public var output: String?
    public var error: String?

    public init(success: Bool, output: String? = nil, error: String? = nil) {
        self.success = success
        self.output = output
        self.error = error
    }

    public static func ok(_ output: String? = nil) -> IPCResponse {
        IPCResponse(success: true, output: output)
    }

    public static func fail(_ error: String) -> IPCResponse {
        IPCResponse(success: false, error: error)
    }
}

// MARK: - IPC Client

public final class IPCClient: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.connectionFailed("socket() failed")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
        }

        // Send request
        let data = try JSONEncoder().encode(request)
        let message = data + Data([0x0a]) // newline delimiter
        message.withUnsafeBytes { ptr in
            _ = Darwin.send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        // Read response
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[..<n])
            if buf[..<n].contains(0x0a) { break }
        }

        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }
}

// MARK: - IPC Server

public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private var serverFd: Int32 = -1
    private var running = false

    public var handler: (@Sendable (IPCRequest) async -> IPCResponse)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        // Remove stale socket
        unlink(socketPath)

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            throw IPCError.bindFailed("socket() failed")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFd)
            throw IPCError.bindFailed("bind() failed: \(String(cString: strerror(errno)))")
        }

        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw IPCError.bindFailed("listen() failed")
        }

        running = true
    }

    public func acceptLoop() async {
        while running {
            let clientFd = accept(serverFd, nil, nil)
            if clientFd < 0 {
                if !running { break }
                continue
            }

            let handler = self.handler
            Task {
                await Self.handleClient(fd: clientFd, handler: handler)
            }
        }
    }

    private static func handleClient(fd: Int32, handler: (@Sendable (IPCRequest) async -> IPCResponse)?) async {
        defer { close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
            if buf[..<n].contains(0x0a) { break }
        }

        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data),
              let handler = handler else {
            let errorResp = IPCResponse.fail("invalid request")
            if let respData = try? JSONEncoder().encode(errorResp) {
                respData.withUnsafeBytes { ptr in
                    _ = Darwin.send(fd, ptr.baseAddress!, ptr.count, 0)
                }
            }
            return
        }

        let response = await handler(request)
        if let respData = try? JSONEncoder().encode(response) {
            let message = respData + Data([0x0a])
            message.withUnsafeBytes { ptr in
                _ = Darwin.send(fd, ptr.baseAddress!, ptr.count, 0)
            }
        }
    }

    public func stop() {
        running = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }
}

// MARK: - Errors

public enum IPCError: Error {
    case connectionFailed(String)
    case bindFailed(String)
}
