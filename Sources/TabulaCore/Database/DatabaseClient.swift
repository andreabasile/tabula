import Foundation

public protocol DatabaseClient: Sendable {
    func execute(_ sql: String) async throws -> QueryResult
    /// Runs the statements atomically, as the commit of pending edits needs.
    func executeInTransaction(_ statements: [String]) async throws
    func close() async
}

public struct ConnectionStatus: Equatable, Sendable {
    public var openedAt: Date?
    public var tokenIssuedAt: Date?
    public var tokenExpiresAt: Date?
    public var reconnectCount: Int

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
