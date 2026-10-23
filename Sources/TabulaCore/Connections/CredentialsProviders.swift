import Foundation

public struct PostgresCredentialsProvider: CredentialsProviding {
    private let settings: PostgresSettings
    private let password: @Sendable () async throws -> String?

    public init(settings: PostgresSettings, password: @escaping @Sendable () async throws -> String?) {
        self.settings = settings
        self.password = password
    }

    public func credentials() async throws -> ConnectionCredentials {
        ConnectionCredentials(
            host: settings.host,
            port: settings.port,
            user: settings.user,
            password: try await password(),
            database: settings.database,
            sslMode: settings.sslMode
        )
    }

    public func invalidate() async {}
}

public struct DSQLCredentialsProvider: CredentialsProviding {
    public static let port = 5432

    private let settings: DSQLSettings
    private let tokens: CachedTokenProvider

    public init(settings: DSQLSettings, tokens: CachedTokenProvider) {
        self.settings = settings
        self.tokens = tokens
    }

    public func credentials() async throws -> ConnectionCredentials {
        let token = try await tokens.token(for: TokenRequest(settings: settings))
        return ConnectionCredentials(
            host: settings.endpoint.trimmingCharacters(in: .whitespaces),
            port: Self.port,
            user: settings.user,
            password: token.value,
            database: settings.database,
            sslMode: .required,
            token: token
        )
    }

    public func invalidate() async {
        guard let request = try? TokenRequest(settings: settings) else { return }
        await tokens.invalidate(request)
    }
}
