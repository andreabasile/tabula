import Foundation

/// Keeps one logical session alive over many physical connections: recycles the
/// connection before DSQL's 60-minute cap, and reconnects (with a fresh token)
/// when the server drops it.
public actor ManagedSession {
    private let opener: ConnectionOpening
    private let credentialsProvider: CredentialsProviding
    private let lifetime: ConnectionLifetimePolicy
    private let now: @Sendable () -> Date
    private var client: DatabaseClient?
    private var opening: Task<DatabaseClient, Error>?
    private var hasConnectedBefore = false
    /// Set by close(): late queries (e.g. from a window being closed) must not reopen the session.
    private var isClosed = false
    private var status = ConnectionStatus()
    private var statusListener: (@Sendable (ConnectionStatus) -> Void)?

    public init(
        opener: ConnectionOpening,
        credentialsProvider: CredentialsProviding,
        lifetime: ConnectionLifetimePolicy,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.opener = opener
        self.credentialsProvider = credentialsProvider
        self.lifetime = lifetime
        self.now = now
    }

    public func onStatusChange(_ listener: @escaping @Sendable (ConnectionStatus) -> Void) {
        statusListener = listener
        listener(status)
    }

    public func connect() async throws {
        isClosed = false
        _ = try await activeClient()
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        try await withReconnect(retrySafe: isRetrySafe(sql)) { try await $0.execute(sql) }
    }

    /// Streams rows; a dropped connection is retried only for reads that delivered nothing yet.
    public func stream(_ sql: String, chunkSize: Int = 500, onChunk: @escaping @Sendable (ResultChunk) -> Void) async throws -> StreamSummary {
        let retrySafe = await isRetrySafe(sql)
        let delivered = DeliveryFlag()
        let tracking: @Sendable (ResultChunk) -> Void = { chunk in
            delivered.mark()
            onChunk(chunk)
        }
        do {
            return try await withReconnect(retrySafe: false) { try await $0.stream(sql, chunkSize: chunkSize, onChunk: tracking) }
        } catch let error as DatabaseError where error.isConnectionLevel && !delivered.value && retrySafe {
            return try await activeClient().stream(sql, chunkSize: chunkSize, onChunk: tracking)
        }
    }

    /// Stops the statement currently running on this session, if any.
    public func cancelRunningQuery() {
        // shortcut: PQcancel blocks this actor until the server answers, so the window's other queries wait briefly; call it off the actor if that delay shows.
        client?.cancel()
    }

    public func executeInTransaction(_ statements: [String]) async throws {
        // A failed COMMIT is never replayed: we cannot know whether it landed.
        try await withReconnect(retrySafe: false) { try await $0.executeInTransaction(statements) }
    }

    /// Forces a new connection (and a new token), like TablePlus's "Reconnect".
    public func reconnect() async throws {
        isClosed = false
        await dropConnection()
        await credentialsProvider.invalidate()
        _ = try await activeClient()
    }

    public func close() async {
        isClosed = true
        await dropConnection()
        status.openedAt = nil
        publish()
    }

    private func withReconnect<T: Sendable>(retrySafe: Bool, _ operation: (DatabaseClient) async throws -> T) async throws -> T {
        let connection = try await activeClient()
        do {
            return try await operation(connection)
        } catch let error as DatabaseError where error.isConnectionLevel {
            await dropConnection()
            await credentialsProvider.invalidate()
            let fresh = try await activeClient()
            guard retrySafe else { throw error }
            return try await operation(fresh)
        }
    }

    private func activeClient() async throws -> DatabaseClient {
        guard !isClosed else { throw Self.closedError }
        if let client, let openedAt = status.openedAt {
            if !lifetime.shouldRecycle(openedAt: openedAt, now: now()) { return client }
            // Recycling now would silently roll back the transaction the user has open.
            if await client.isInTransaction() {
                guard !isClosed else { throw Self.closedError }
                return client
            }
        }
        // Concurrent callers share one connect instead of racing to open several.
        if let opening { return try await opening.value }
        let task = Task { try await openFreshClient() }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    private func openFreshClient() async throws -> DatabaseClient {
        await dropConnection()
        let (opened, credentials) = try await openWithFreshTokenOnAuthFailure()
        // close() may have run while the token or the connection was on its way.
        guard !isClosed else {
            await opened.close()
            throw Self.closedError
        }
        client = opened
        status.openedAt = now()
        status.tokenIssuedAt = credentials.token?.issuedAt
        status.tokenExpiresAt = credentials.token?.expiresAt
        status.server = await opened.serverInfo()
        if hasConnectedBefore { status.reconnectCount += 1 }
        hasConnectedBefore = true
        publish()
        return opened
    }

    /// A cached token can be rejected (e.g. the IAM role changed): retry once with a new one.
    private func openWithFreshTokenOnAuthFailure() async throws -> (DatabaseClient, ConnectionCredentials) {
        let credentials = try await credentialsProvider.credentials()
        do {
            return (try await opener.open(credentials), credentials)
        } catch DatabaseError.authenticationFailed(_) where credentials.token != nil {
            await credentialsProvider.invalidate()
            let fresh = try await credentialsProvider.credentials()
            return (try await opener.open(fresh), fresh)
        }
    }

    /// Only reads are replayed after a dropped connection, and not inside a transaction:
    /// on a new connection they would run outside the user's open transaction.
    private func isRetrySafe(_ sql: String) async -> Bool {
        guard StatementClassifier.isReadOnly(sql) else { return false }
        return !(await client?.isInTransaction() ?? false)
    }

    private static var closedError: DatabaseError {
        .connectionLost(String(localized: "the session was closed"))
    }

    private func dropConnection() async {
        guard let client else { return }
        self.client = nil
        await client.close()
    }

    private func publish() {
        statusListener?(status)
    }
}

final class DeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    func mark() { lock.withLock { delivered = true } }
    var value: Bool { lock.withLock { delivered } }
}
