import Foundation

public enum ConnectionTag: String, Codable, CaseIterable, Sendable {
    case local, testing, development, staging, production

    public var isProduction: Bool { self == .production }
}

public enum SSLMode: String, Codable, CaseIterable, Sendable {
    case disabled = "DISABLED"
    case preferred = "PREFERRED"
    case required = "REQUIRED"
}

public enum PasswordStorage: String, Codable, CaseIterable, Sendable {
    case keychain
    case askEveryTime
    case none
}

public struct PostgresSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var sslMode: SSLMode
    public var passwordStorage: PasswordStorage

    public init(
        host: String = "127.0.0.1",
        port: Int = 5432,
        user: String = "",
        database: String = "",
        sslMode: SSLMode = .preferred,
        passwordStorage: PasswordStorage = .keychain
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.sslMode = sslMode
        self.passwordStorage = passwordStorage
    }
}

public struct DSQLSettings: Codable, Equatable, Sendable {
    public static let adminRole = "admin"

    public var endpoint: String
    /// Empty means "derive it from the endpoint".
    public var region: String
    /// Empty means the AWS CLI default credential chain.
    public var awsProfile: String
    public var user: String
    public var database: String
    public var tokenLifetimeSeconds: Int

    public init(
        endpoint: String = "",
        region: String = "",
        awsProfile: String = "",
        user: String = DSQLSettings.adminRole,
        database: String = "postgres",
        tokenLifetimeSeconds: Int = 900
    ) {
        self.endpoint = endpoint
        self.region = region
        self.awsProfile = awsProfile
        self.user = user
        self.database = database
        self.tokenLifetimeSeconds = tokenLifetimeSeconds
    }

    public var isAdmin: Bool { user == Self.adminRole }

    public var resolvedRegion: String? {
        let explicit = region.trimmingCharacters(in: .whitespaces)
        return explicit.isEmpty ? DSQLEndpoint.region(from: endpoint) : explicit
    }
}

public enum ConnectionKind: Codable, Equatable, Sendable {
    case postgres(PostgresSettings)
    case dsql(DSQLSettings)

    public var driverName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .dsql: "Aurora DSQL"
        }
    }
}

public struct ConnectionConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var tag: ConnectionTag
    public var group: String
    public var kind: ConnectionKind
    public var safeMode: SafeMode

    public init(
        id: UUID = UUID(),
        name: String,
        tag: ConnectionTag = .local,
        group: String = "",
        kind: ConnectionKind,
        safeMode: SafeMode = .silent
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.group = group
        self.kind = kind
        self.safeMode = safeMode
    }

    public var host: String {
        switch kind {
        case .postgres(let settings): settings.host
        case .dsql(let settings): settings.endpoint
        }
    }

    public var database: String {
        switch kind {
        case .postgres(let settings): settings.database
        case .dsql(let settings): settings.database
        }
    }

    /// The same connection pointed at another database, as TablePlus's "Open database".
    public func switchingDatabase(to database: String) -> ConnectionConfig {
        var copy = self
        switch kind {
        case .postgres(var settings):
            settings.database = database
            copy.kind = .postgres(settings)
        case .dsql(var settings):
            settings.database = database
            copy.kind = .dsql(settings)
        }
        return copy
    }

    public var user: String {
        switch kind {
        case .postgres(let settings): settings.user
        case .dsql(let settings): settings.user
        }
    }
}
