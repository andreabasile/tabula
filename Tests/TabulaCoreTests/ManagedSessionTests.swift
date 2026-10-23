import Foundation
import Testing
@testable import TabulaCore

struct ManagedSessionTests {
    let request = TokenRequest(endpoint: "c.dsql.eu-west-1.on.aws", region: "eu-west-1", awsProfile: "", isAdmin: true, lifetimeSeconds: 900)

    func makeSession(opener: FakeOpener, clock: TestClock, generator: CountingGenerator) -> ManagedSession {
        let tokens = CachedTokenProvider(generator: generator, now: clock.now)
        let provider = DSQLCredentialsProvider(settings: DSQLSettings(endpoint: request.endpoint), tokens: tokens)
        return ManagedSession(opener: opener, credentialsProvider: provider, lifetime: .dsql, now: clock.now)
    }

    @Test func connectsWithTokenAsPassword() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        _ = try await session.execute("SELECT 1")
        let credentials = await opener.opened
        #expect(credentials.map(\.password) == ["token-1"])
        #expect(credentials.first?.sslMode == .required)
        #expect(credentials.first?.user == "admin")
    }

    @Test func recyclesConnectionAfter55MinutesWithFreshToken() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        _ = try await session.execute("SELECT 1")
        clock.advance(30 * 60)
        _ = try await session.execute("SELECT 1")
        #expect(await opener.opened.count == 1)
        clock.advance(25 * 60)
        _ = try await session.execute("SELECT 1")
        let opened = await opener.opened
        #expect(opened.count == 2)
        #expect(opened.last?.password == "token-2")
        #expect(await opener.closedCount == 1)
    }

    @Test func reconnectsAndRetriesReadsWhenConnectionDrops() async throws {
        let clock = TestClock()
        let opener = FakeOpener(failFirstQueryWith: .connectionLost("server closed the connection"))
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        let result = try await session.execute("SELECT 1")
        #expect(result.commandTag == "SELECT 1")
        #expect(await opener.opened.count == 2)
    }

    @Test func doesNotReplayWritesAfterDrop() async throws {
        let clock = TestClock()
        let opener = FakeOpener(failFirstQueryWith: .connectionLost("gone"))
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        await #expect(throws: DatabaseError.connectionLost("gone")) { _ = try await session.execute("DELETE FROM t") }
        #expect(await opener.executed == ["DELETE FROM t"])
        #expect(await opener.opened.count == 2)
    }

    @Test func retriesConnectOnceWithNewTokenWhenRejected() async throws {
        let clock = TestClock()
        let generator = CountingGenerator(clock: clock)
        let opener = FakeOpener(rejectPasswords: ["token-1"])
        let session = makeSession(opener: opener, clock: clock, generator: generator)
        try await session.connect()
        #expect(await opener.opened.map(\.password) == ["token-1", "token-2"])
    }

    @Test func publishesTokenTimesAndReconnects() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        let recorder = StatusRecorder()
        await session.onStatusChange { recorder.append($0) }
        try await session.connect()
        try await session.reconnect()
        let last = recorder.last
        #expect(last?.reconnectCount == 1)
        #expect(last?.tokenExpiresAt == clock.now().addingTimeInterval(900))
    }
}

// MARK: - Test doubles

actor FakeOpener: ConnectionOpening {
    private(set) var opened: [ConnectionCredentials] = []
    private(set) var executed: [String] = []
    private(set) var closedCount = 0
    private var pendingFailure: DatabaseError?
    private let rejectPasswords: Set<String>

    init(failFirstQueryWith failure: DatabaseError? = nil, rejectPasswords: Set<String> = []) {
        self.pendingFailure = failure
        self.rejectPasswords = rejectPasswords
    }

    nonisolated func open(_ credentials: ConnectionCredentials) async throws -> DatabaseClient {
        try await record(credentials)
        return FakeClient(owner: self)
    }

    private func record(_ credentials: ConnectionCredentials) throws {
        opened.append(credentials)
        if let password = credentials.password, rejectPasswords.contains(password) {
            throw DatabaseError.authenticationFailed("access denied")
        }
    }

    func run(_ sql: String) throws -> QueryResult {
        executed.append(sql)
        if let failure = pendingFailure {
            pendingFailure = nil
            throw failure
        }
        return QueryResult(columns: [ResultColumn(name: "?column?", typeName: "int4")], rows: [[.text("1")]], commandTag: "SELECT 1", duration: 0)
    }

    func didClose() { closedCount += 1 }
}

struct FakeClient: DatabaseClient {
    let owner: FakeOpener
    func execute(_ sql: String) async throws -> QueryResult { try await owner.run(sql) }
    func executeInTransaction(_ statements: [String]) async throws {
        for statement in statements { _ = try await owner.run(statement) }
    }
    func close() async { await owner.didClose() }
}

final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ConnectionStatus] = []
    func append(_ status: ConnectionStatus) { lock.withLock { statuses.append(status) } }
    var last: ConnectionStatus? { lock.withLock { statuses.last } }
}
