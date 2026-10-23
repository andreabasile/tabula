import Foundation

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Self.environment()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: CommandOutput(exitCode: finished.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Apps launched from Finder get a minimal PATH; the AWS CLI may need to spawn
    /// helpers (credential_process, SSO) that live in Homebrew.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (current + extraPaths).joined(separator: ":")
        environment["AWS_PAGER"] = ""
        return environment
    }
}
