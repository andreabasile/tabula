import Foundation
import Testing
@testable import TabulaCore

struct DSQLEndpointTests {
    @Test func derivesRegionFromEndpoint() {
        #expect(DSQLEndpoint.region(from: "abc123.dsql.eu-west-1.on.aws") == "eu-west-1")
        #expect(DSQLEndpoint.region(from: "localhost") == nil)
        #expect(DSQLEndpoint.isDSQLHost("abc.dsql.us-east-1.on.aws"))
    }

    @Test func explicitRegionWins() {
        let settings = DSQLSettings(endpoint: "abc.dsql.eu-west-1.on.aws", region: "us-east-2")
        #expect(settings.resolvedRegion == "us-east-2")
    }

    @Test func missingRegionIsAConfigurationError() {
        #expect(throws: DSQLConfigurationError.self) { try TokenRequest(settings: DSQLSettings(endpoint: "my-alias.internal")) }
    }
}

struct AWSCLITokenGeneratorTests {
    let request = TokenRequest(endpoint: "c.dsql.eu-west-1.on.aws", region: "eu-west-1", awsProfile: "dev", isAdmin: true, lifetimeSeconds: 900)

    @Test func adminUsesAdminSubcommandAndProfile() {
        #expect(AWSCLITokenGenerator.arguments(for: request) == [
            "dsql", "generate-db-connect-admin-auth-token",
            "--hostname", "c.dsql.eu-west-1.on.aws", "--region", "eu-west-1", "--expires-in", "900",
            "--profile", "dev",
        ])
    }

    @Test func customRoleWithDefaultProfile() {
        let custom = TokenRequest(endpoint: "c", region: "r", awsProfile: "", isAdmin: false, lifetimeSeconds: 60)
        let arguments = AWSCLITokenGenerator.arguments(for: custom)
        #expect(arguments[1] == "generate-db-connect-auth-token")
        #expect(!arguments.contains("--profile"))
    }

    @Test func returnsTrimmedTokenWithExpiry() async throws {
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        let generator = AWSCLITokenGenerator(
            runner: StubRunner(output: CommandOutput(exitCode: 0, stdout: "tok-en\n", stderr: "")),
            executablePath: { "/usr/bin/aws" },
            now: { issuedAt }
        )
        let token = try await generator.generateToken(for: request)
        #expect(token.value == "tok-en")
        #expect(token.expiresAt == issuedAt.addingTimeInterval(900))
    }

    @Test func explainsExpiredSSO() async {
        let generator = AWSCLITokenGenerator(
            runner: StubRunner(output: CommandOutput(exitCode: 255, stdout: "", stderr: "Error when retrieving token from sso: Token has expired and refresh failed")),
            executablePath: { "/usr/bin/aws" }
        )
        await #expect {
            _ = try await generator.generateToken(for: request)
        } throws: { error in
            (error as? LocalizedError)?.errorDescription?.contains("aws sso login") == true
        }
    }

    @Test func missingCLI() async {
        let generator = AWSCLITokenGenerator(runner: StubRunner(output: .init(exitCode: 0, stdout: "", stderr: "")), executablePath: { nil })
        await #expect(throws: TokenGenerationError.awsCLINotFound) { _ = try await generator.generateToken(for: request) }
    }
}

struct CachedTokenProviderTests {
    let request = TokenRequest(endpoint: "c", region: "r", awsProfile: "", isAdmin: true, lifetimeSeconds: 900)

    @Test func reusesTokenUntilCloseToExpiry() async throws {
        let clock = TestClock()
        let generator = CountingGenerator(clock: clock)
        let provider = CachedTokenProvider(generator: generator, safetyMargin: 60, now: clock.now)

        let first = try await provider.token(for: request)
        clock.advance(800)
        #expect(try await provider.token(for: request) == first)
        clock.advance(50)
        #expect(try await provider.token(for: request) != first)
        #expect(await generator.calls == 2)
    }

    @Test func invalidateForcesNewToken() async throws {
        let clock = TestClock()
        let generator = CountingGenerator(clock: clock)
        let provider = CachedTokenProvider(generator: generator, now: clock.now)
        _ = try await provider.token(for: request)
        await provider.invalidate(request)
        _ = try await provider.token(for: request)
        #expect(await generator.calls == 2)
    }

    @Test func concurrentRequestsShareOneGeneration() async throws {
        let clock = TestClock()
        let generator = CountingGenerator(clock: clock, delay: .milliseconds(50))
        let provider = CachedTokenProvider(generator: generator, now: clock.now)
        async let a = provider.token(for: request)
        async let b = provider.token(for: request)
        _ = try await (a, b)
        #expect(await generator.calls == 1)
    }
}

struct ConnectionLifetimePolicyTests {
    @Test func dsqlRecyclesAt55Minutes() {
        let opened = Date(timeIntervalSince1970: 0)
        #expect(!ConnectionLifetimePolicy.dsql.shouldRecycle(openedAt: opened, now: opened.addingTimeInterval(54 * 60)))
        #expect(ConnectionLifetimePolicy.dsql.shouldRecycle(openedAt: opened, now: opened.addingTimeInterval(55 * 60)))
        #expect(!ConnectionLifetimePolicy.unlimited.shouldRecycle(openedAt: opened, now: .distantFuture))
    }
}

// MARK: - Test doubles

struct StubRunner: CommandRunning {
    let output: CommandOutput
    func run(executable: String, arguments: [String]) async throws -> CommandOutput { output }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

actor CountingGenerator: AuthTokenGenerating {
    private(set) var calls = 0
    private let clock: TestClock
    private let delay: Duration

    init(clock: TestClock, delay: Duration = .zero) {
        self.clock = clock
        self.delay = delay
    }

    func generateToken(for request: TokenRequest) async throws -> AuthToken {
        calls += 1
        let issued = clock.now()
        if delay > .zero { try await Task.sleep(for: delay) }
        return AuthToken(value: "token-\(calls)", issuedAt: issued, expiresAt: issued.addingTimeInterval(TimeInterval(request.lifetimeSeconds)))
    }
}
