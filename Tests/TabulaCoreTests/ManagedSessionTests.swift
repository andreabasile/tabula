import Foundation
import Testing
@testable import TabulaCore

struct ManagedSessionTests {
    let request = TokenRequest(endpoint: "c.dsql.eu-west-1.on.aws", region: "eu-west-1", awsProfile: "", isAdmin: true, lifetimeSeconds: 900)

    func makeSession(opener: ConnectionOpening, clock: TestClock, generator: CountingGenerator) -> ManagedSession {
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

    @Test func doesNotRecycleInsideAnOpenTransaction() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        _ = try await session.execute("BEGIN")
        await opener.setInTransaction(true)
        clock.advance(56 * 60)
        _ = try await session.execute("SELECT 1")
        #expect(await opener.opened.count == 1)
    }

    @Test func readsInsideATransactionAreNotReplayedAfterDrop() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        try await session.connect()
        await opener.setInTransaction(true)
        await opener.failNextQuery(with: .connectionLost("gone"))
        await #expect(throws: DatabaseError.connectionLost("gone")) { _ = try await session.execute("SELECT 1") }
        #expect(await opener.executed == ["SELECT 1"])
    }

    @Test func closedSessionDoesNotReopen() async throws {
        let clock = TestClock()
        let opener = FakeOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        try await session.connect()
        await session.close()
        await #expect(throws: DatabaseError.self) { _ = try await session.execute("SELECT 1") }
        #expect(await opener.opened.count == 1)
        try await session.connect()
        #expect(await opener.opened.count == 2)
    }

    @Test func closeDuringConnectDoesNotLeaveALiveConnection() async throws {
        let clock = TestClock()
        let opener = GatedOpener()
        let session = makeSession(opener: opener, clock: clock, generator: CountingGenerator(clock: clock))
        let connecting = Task { try await session.connect() }
        while !(await opener.isOpening) { await Task.yield() }
        await session.close()
        await opener.release()
        await #expect(throws: DatabaseError.self) { try await connecting.value }
        #expect(await opener.fake.closedCount == 1)
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

    private(set) var inTransaction = false
    func setInTransaction(_ value: Bool) { inTransaction = value }
    func failNextQuery(with failure: DatabaseError) { pendingFailure = failure }
}

/// Holds open() until release(), so a test can close the session while a connection is on its way.
actor GatedOpener: ConnectionOpening {
    let fake = FakeOpener()
    private var pending: CheckedContinuation<Void, Never>?
    var isOpening: Bool { pending != nil }

    nonisolated func open(_ credentials: ConnectionCredentials) async throws -> DatabaseClient {
        await hold()
        return try await fake.open(credentials)
    }

    private func hold() async {
        await withCheckedContinuation { pending = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

struct FakeClient: DatabaseClient {
    let owner: FakeOpener
    func execute(_ sql: String) async throws -> QueryResult { try await owner.run(sql) }
    func executeInTransaction(_ statements: [String]) async throws {
        for statement in statements { _ = try await owner.run(statement) }
    }
    func close() async { await owner.didClose() }
    func isInTransaction() async -> Bool { await owner.inTransaction }
}

struct LibPQParametersTests {
    @Test func dsqlVerifiesAgainstTheMacOSCABundle() {
        let token = AuthToken(value: "t", issuedAt: .now, expiresAt: .now)
        let credentials = ConnectionCredentials(host: "c.dsql.eu-west-1.on.aws", port: 5432, user: "admin", password: "t", database: "postgres", sslMode: .required, token: token)
        let pairs = Dictionary(uniqueKeysWithValues: LibPQParameters.make(for: credentials).pairs)
        #expect(pairs["sslmode"] == "verify-full")
        #expect(pairs["sslrootcert"] == "/etc/ssl/cert.pem")
    }

    @Test func editsThatMatchNoRowAreDetected() {
        #expect(LibPQErrors.matchedNoRow("UPDATE 0"))
        #expect(LibPQErrors.matchedNoRow("DELETE 0"))
        #expect(!LibPQErrors.matchedNoRow("UPDATE 1"))
        #expect(!LibPQErrors.matchedNoRow("INSERT 0 1"))
    }
}

final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ConnectionStatus] = []
    func append(_ status: ConnectionStatus) { lock.withLock { statuses.append(status) } }
    var last: ConnectionStatus? { lock.withLock { statuses.last } }
}
