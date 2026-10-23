import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandOutput
}

public enum TokenGenerationError: Error, Equatable, LocalizedError {
    case awsCLINotFound
    case commandFailed(stderr: String)
    case emptyToken

    public var errorDescription: String? {
        switch self {
        case .awsCLINotFound:
            "AWS CLI non trovata. Installala (brew install awscli) o indica il percorso nelle impostazioni."
        case .commandFailed(let stderr):
            Self.explain(stderr)
        case .emptyToken:
            "La AWS CLI non ha restituito alcun token."
        }
    }

    private static func explain(_ stderr: String) -> String {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("sso") && (lowered.contains("expired") || lowered.contains("token")) {
            return "Sessione AWS SSO scaduta: esegui `aws sso login` per il profilo.\n\(message)"
        }
        if lowered.contains("unable to locate credentials") {
            return "Nessuna credenziale AWS trovata per questo profilo.\n\(message)"
        }
        return message.isEmpty ? "La AWS CLI è terminata con errore." : message
    }
}

/// Delegates credential resolution (profiles, SSO, assumed roles, env vars) to the
/// AWS CLI so the app honours exactly what `aws` does in the user's terminal.
public struct AWSCLITokenGenerator: AuthTokenGenerating {
    public static let candidatePaths = [
        "/opt/homebrew/bin/aws",
        "/usr/local/bin/aws",
        "/usr/bin/aws",
    ]

    private let runner: CommandRunning
    private let executablePath: @Sendable () -> String?
    private let now: @Sendable () -> Date

    public init(
        runner: CommandRunning = ProcessCommandRunner(),
        executablePath: @escaping @Sendable () -> String? = AWSCLITokenGenerator.locateExecutable,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.executablePath = executablePath
        self.now = now
    }

    public func generateToken(for request: TokenRequest) async throws -> AuthToken {
        guard let executable = executablePath() else { throw TokenGenerationError.awsCLINotFound }
        let issuedAt = now()
        let output = try await runner.run(executable: executable, arguments: Self.arguments(for: request))
        guard output.exitCode == 0 else { throw TokenGenerationError.commandFailed(stderr: output.stderr) }
        let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw TokenGenerationError.emptyToken }
        return AuthToken(
            value: token,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(TimeInterval(request.lifetimeSeconds))
        )
    }

    public static func arguments(for request: TokenRequest) -> [String] {
        let subcommand = request.isAdmin ? "generate-db-connect-admin-auth-token" : "generate-db-connect-auth-token"
        var arguments = [
            "dsql", subcommand,
            "--hostname", request.endpoint,
            "--region", request.region,
            "--expires-in", String(request.lifetimeSeconds),
        ]
        if !request.awsProfile.isEmpty {
            arguments += ["--profile", request.awsProfile]
        }
        return arguments
    }

    @Sendable public static func locateExecutable() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
