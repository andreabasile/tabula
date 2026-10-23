import Darwin
import Foundation

/// Runs scripts in a login zsh, so `aws`, `ssh` and the user's PATH work as in Terminal.
/// Each script leads its own process group, so the whole tree (zsh → bash → aws →
/// session-manager-plugin) can be stopped with one signal, even after zsh has exited.
public struct SystemScriptLauncher: ScriptLaunching {
    private let registry: TunnelRegistry?

    public init(registry: TunnelRegistry? = nil) {
        self.registry = registry
    }

    public func launch(_ script: String) throws -> RunningScript {
        let process = try ShellProcess(script: script)
        registry?.record(processGroup: process.processGroup, script: script)
        process.onFinish = { [registry] group in registry?.forget(processGroup: group) }
        return process
    }
}

public enum ShellProcessError: Error, LocalizedError {
    case spawnFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let code): "Impossibile avviare lo script: \(String(cString: strerror(code)))"
        }
    }
}

final class ShellProcess: RunningScript, @unchecked Sendable {
    let processGroup: pid_t
    var onFinish: ((pid_t) -> Void)?
    private let lock = NSLock()
    private var buffer = ""
    private var status: Int32?
    private let reader: FileHandle

    init(script: String) throws {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw ShellProcessError.spawnFailed(errno) }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Ignored signals survive exec: without resetting them, a script started by an app
        // that ignores SIGTERM (Tabula does, to quit cleanly) could never be stopped.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addclose(&actions, readFD)

        // Explicit types: older compilers cannot infer the optional element on their own.
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/zsh", "-l", "-c", script].map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = Self.environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            environment.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, arguments, environment)
        close(writeFD)
        guard result == 0 else {
            close(readFD)
            throw ShellProcessError.spawnFailed(result)
        }
        processGroup = pid
        reader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.append(String(decoding: data, as: UTF8.self))
        }
    }

    var isRunning: Bool { exitCode == nil }

    var exitCode: Int32? {
        lock.withLock {
            if let status { return status }
            var raw: Int32 = 0
            guard waitpid(processGroup, &raw, WNOHANG) == processGroup else { return nil }
            // WIFEXITED / WEXITSTATUS are macros Swift cannot import.
            let finished: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            status = finished
            return finished
        }
    }

    var output: String { lock.withLock { buffer } }

    func terminate() {
        // The negative pid signals the whole group, including grandchildren.
        let group = processGroup
        kill(-group, SIGTERM)
        _ = exitCode
        onFinish?(group)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }

    private func append(_ chunk: String) {
        lock.withLock {
            buffer += chunk
            if buffer.count > 20_000 { buffer = String(buffer.suffix(20_000)) }
        }
    }

    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = ([environment["PATH"]].compactMap { $0 } + extraPaths).joined(separator: ":")
        environment["AWS_PAGER"] = ""
        return environment
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
