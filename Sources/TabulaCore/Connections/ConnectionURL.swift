import Foundation

/// "Import from URL" and "Copy as URL". A DSQL host in the URL becomes a DSQL
/// connection, since its password would only be a short-lived token anyway.
public enum ConnectionURL {
    public struct Parsed: Equatable, Sendable {
        public let kind: ConnectionKind
        public let password: String?
        public var warning: String?
    }

    public static func parse(_ text: String) -> Parsed? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["postgres", "postgresql"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty
        else { return nil }
        let user = components.user?.removingPercentEncoding ?? ""
        let database = String(components.path.drop { $0 == "/" })
        if DSQLEndpoint.isDSQLHost(host) {
            return Parsed(kind: .dsql(DSQLSettings(endpoint: host, userOrDefault: user, databaseOrDefault: database)), password: nil)
        }
        let requestedSSL = components.queryItems?.first { $0.name == "sslmode" }?.value?.lowercased()
        let sslMode = requestedSSL.flatMap(sslMode(from:)) ?? .preferred
        let settings = PostgresSettings(host: host, port: components.port ?? 5432, user: user, database: database, sslMode: sslMode)
        let downgraded = ["verify-ca", "verify-full"].contains(requestedSSL)
        return Parsed(kind: .postgres(settings), password: components.password?.removingPercentEncoding, warning: downgraded ? SSLMode.unverifiedCertificateWarning : nil)
    }

    public static func format(_ connection: ConnectionConfig) -> String {
        var components = URLComponents()
        components.scheme = "postgresql"
        components.user = connection.user.isEmpty ? nil : connection.user
        components.host = connection.host
        components.path = "/" + connection.database
        switch connection.kind {
        case .postgres(let settings):
            components.port = settings.port
            components.queryItems = [URLQueryItem(name: "sslmode", value: settings.sslMode.libpqName)]
        case .dsql:
            components.port = DSQLCredentialsProvider.port
            components.queryItems = [URLQueryItem(name: "sslmode", value: "verify-full")]
        }
        return components.string ?? ""
    }

    private static func sslMode(from value: String) -> SSLMode? {
        switch value {
        case "disable": .disabled
        case "allow", "prefer": .preferred
        case "require", "verify-ca", "verify-full": .required
        default: nil
        }
    }
}
