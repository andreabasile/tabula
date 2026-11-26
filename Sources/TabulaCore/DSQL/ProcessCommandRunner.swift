import Foundation

public struct ProcessCommandRunner: CommandRunning {
    private let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 60) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ChildProcess.environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Both pipes drain while the command runs: a full one would block it forever.
        let output = PipeCollector(stdout)
        let errors = PipeCollector(stderr)
        try process.run()
        // A hung command (SSO prompt, credential_process, network) must not block every connect:
        // SIGTERM at the timeout, SIGKILL if it is still there 2 s later.
        let start = ContinuousClock.now
        var timedOut = false
        while process.isRunning {
            let elapsed = ContinuousClock.now - start
            if elapsed >= .seconds(timeoutSeconds + 2) {
                kill(process.processIdentifier, SIGKILL)
            } else if elapsed >= .seconds(timeoutSeconds), !timedOut {
                timedOut = true
                process.terminate()
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // What it wrote before exiting is still in the pipes; a helper it left behind may keep them
        // open, so wait for their end only briefly.
        let drainEnd = ContinuousClock.now + .seconds(1)
        while !(output.reachedEnd && errors.reachedEnd), ContinuousClock.now < drainEnd {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let err = errors.stop()
        let message = timedOut ? err + "\n" + String(localized: "The command did not finish within \(timeoutSeconds) seconds.") : err
        return CommandOutput(exitCode: process.terminationStatus, stdout: output.stop(), stderr: message)
    }
}

/// Collects a pipe's output as it arrives, without ever blocking on it.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var data = Data()
    private var ended = false

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.withLock {
                if chunk.isEmpty { ended = true } else { data.append(chunk) }
            }
            if chunk.isEmpty { handle.readabilityHandler = nil }
        }
    }

    var reachedEnd: Bool { lock.withLock { ended } }

    func stop() -> String {
        handle.readabilityHandler = nil
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

/// The environment for child processes (aws, scripts): apps launched from Finder get a minimal
/// PATH, while the AWS CLI and tunnel scripts need Homebrew's tools and helpers.
enum ChildProcess {
    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = ([environment["PATH"]].compactMap { $0 } + extraPaths).joined(separator: ":")
        environment["AWS_PAGER"] = ""
        return environment
    }
}
