import Foundation

public protocol DatabaseClient: Sendable {
    func execute(_ sql: String) async throws -> QueryResult
    /// Delivers rows in chunks while the server sends them, as TablePlus fills its grid.
    func stream(_ sql: String, chunkSize: Int, onChunk: @escaping @Sendable (ResultChunk) -> Void) async throws -> StreamSummary
    /// Runs the statements atomically, as the commit of pending edits needs.
    func executeInTransaction(_ statements: [String]) async throws
    /// Asks the server to stop the running statement; safe to call from any thread.
    func cancel()
    func serverInfo() async -> ServerInfo
    func close() async
}

public struct ResultChunk: Sendable {
    public let columns: [ResultColumn]
    public let rows: [[CellValue]]

    public init(columns: [ResultColumn], rows: [[CellValue]]) {
        self.columns = columns
        self.rows = rows
    }
}

public struct StreamSummary: Equatable, Sendable {
    public let columns: [ResultColumn]
    public let rowCount: Int
    public let commandTag: String
    public let duration: TimeInterval

    public init(columns: [ResultColumn], rowCount: Int, commandTag: String, duration: TimeInterval) {
        self.columns = columns
        self.rowCount = rowCount
        self.commandTag = commandTag
        self.duration = duration
    }
}

public struct ServerInfo: Equatable, Sendable {
    public var version: String?
    public var tlsProtocol: String?

    public init(version: String? = nil, tlsProtocol: String? = nil) {
        self.version = version
        self.tlsProtocol = tlsProtocol
    }
}

extension DatabaseClient {
    /// Clients without real streaming deliver everything as one chunk.
    public func stream(_ sql: String, chunkSize: Int, onChunk: @escaping @Sendable (ResultChunk) -> Void) async throws -> StreamSummary {
        let result = try await execute(sql)
        if result.returnsRows { onChunk(ResultChunk(columns: result.columns, rows: result.rows)) }
        return StreamSummary(columns: result.columns, rowCount: result.rows.count, commandTag: result.commandTag, duration: result.duration)
    }

    public func cancel() {}

    public func serverInfo() async -> ServerInfo { ServerInfo() }
}

public struct ConnectionStatus: Equatable, Sendable {
    public var openedAt: Date?
    public var tokenIssuedAt: Date?
    public var tokenExpiresAt: Date?
    public var reconnectCount: Int
    public var server = ServerInfo()

    public init(openedAt: Date? = nil, tokenIssuedAt: Date? = nil, tokenExpiresAt: Date? = nil, reconnectCount: Int = 0) {
        self.openedAt = openedAt
        self.tokenIssuedAt = tokenIssuedAt
        self.tokenExpiresAt = tokenExpiresAt
        self.reconnectCount = reconnectCount
    }
}

public struct ConnectionCredentials: Equatable, Sendable {
    public let host: String
    public let port: Int
    public let user: String
    public let password: String?
    public let database: String
    public let sslMode: SSLMode
    public let token: AuthToken?

    public init(host: String, port: Int, user: String, password: String?, database: String, sslMode: SSLMode, token: AuthToken? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.token = token
    }
}

/// Opens one physical connection; the session decides when to call it again.
public protocol ConnectionOpening: Sendable {
    func open(_ credentials: ConnectionCredentials) async throws -> DatabaseClient
}

/// Produces credentials for every (re)connect: for DSQL this is where a fresh
/// IAM token gets minted, for plain Postgres it just returns the saved password.
public protocol CredentialsProviding: Sendable {
    func credentials() async throws -> ConnectionCredentials
    func invalidate() async
}
