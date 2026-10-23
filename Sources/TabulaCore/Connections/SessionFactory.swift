import Foundation

public struct SessionFactory: Sendable {
    private let opener: ConnectionOpening
    private let tokens: CachedTokenProvider

    public init(opener: ConnectionOpening = LibPQOpener(), tokens: CachedTokenProvider) {
        self.opener = opener
        self.tokens = tokens
    }

    public func makeSession(for connection: ConnectionConfig, password: @escaping @Sendable () async throws -> String?) -> ManagedSession {
        switch connection.kind {
        case .postgres(let settings):
            ManagedSession(
                opener: opener,
                credentialsProvider: PostgresCredentialsProvider(settings: settings, password: password),
                lifetime: .unlimited
            )
        case .dsql(let settings):
            ManagedSession(
                opener: opener,
                credentialsProvider: DSQLCredentialsProvider(settings: settings, tokens: tokens),
                lifetime: .dsql
            )
        }
    }
}
