import Foundation

public struct SessionFactory: Sendable {
    private let opener: ConnectionOpening
    private let tokens: CachedTokenProvider
    public let tunnels: TunnelManager

    public init(opener: ConnectionOpening = LibPQOpener(), tokens: CachedTokenProvider, tunnels: TunnelManager) {
        self.opener = opener
        self.tokens = tokens
        self.tunnels = tunnels
    }

    /// `owner` identifies who holds the tunnel open; release it with `tunnels.release(owner:)`.
    public func makeSession(
        for connection: ConnectionConfig,
        owner: UUID = UUID(),
        password: @escaping @Sendable () async throws -> String?
    ) -> ManagedSession {
        let (base, lifetime): (CredentialsProviding, ConnectionLifetimePolicy) = switch connection.kind {
        case .postgres(let settings): (PostgresCredentialsProvider(settings: settings, password: password), .unlimited)
        case .dsql(let settings): (DSQLCredentialsProvider(settings: settings, tokens: tokens), .dsql)
        }
        let provider: CredentialsProviding = if let script = connection.preConnectScript, !script.isEmpty {
            TunnelingCredentialsProvider(base: base, script: script, tunnels: tunnels, owner: owner)
        } else {
            base
        }
        return ManagedSession(opener: opener, credentialsProvider: provider, lifetime: lifetime)
    }
}
