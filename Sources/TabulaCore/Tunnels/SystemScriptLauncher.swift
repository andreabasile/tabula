import Darwin
import Foundation

/// Runs scripts in a login zsh, so `aws`, `ssh` and the user's PATH work as in Terminal.
public struct SystemScriptLauncher: ScriptLaunching {
    public init() {}

    public func launch(_ script: String) throws -> RunningScript {
        try ShellProcess(script: script)
    }
}

final class ShellProcess: RunningScript, @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = ""

    init(script: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ([environment["PATH"]].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["AWS_PAGER"] = ""
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            self?.append(chunk)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    var exitCode: Int32? { process.isRunning ? nil : process.terminationStatus }

    var output: String { lock.withLock { buffer } }

    /// Kills the whole tree: `aws ssm start-session` leaves session-manager-plugin as a
    /// grandchild that would otherwise keep the port open.
    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        (Self.descendants(of: pid) + [pid]).forEach { kill($0, SIGTERM) }
    }

    private func append(_ chunk: String) {
        lock.withLock {
            buffer += chunk
            if buffer.count > 20_000 { buffer = String(buffer.suffix(20_000)) }
        }
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        let children = childPIDs(of: pid)
        return children.flatMap { descendants(of: $0) } + children
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }
}

/// A TCP connect with a short timeout: enough to tell whether a tunnel is listening.
public struct TCPPortProbe: PortProbing {
    public init() {}

    public func isOpen(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Self.connects(host: host, port: port, timeout: 1))
            }
        }
    }

    private static func connects(host: String, port: Int, timeout: Int) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else { return false }
        defer { freeaddrinfo(results) }
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate {
            if connect(info.pointee, timeout: timeout) { return true }
            candidate = info.pointee.ai_next
        }
        return false
    }

    private static func connect(_ info: addrinfo, timeout: Int) -> Bool {
        let socketFD = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(socketFD, F_GETFL)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(socketFD, info.ai_addr, info.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}
