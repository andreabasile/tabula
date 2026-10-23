import Foundation

public struct TokenEvent: Equatable, Sendable {
    public let request: TokenRequest
    public let token: AuthToken
    public let wasRefreshed: Bool
}

/// DSQL validates the token only while a connection is being opened, so a token is
/// reused across connections until it gets close to expiry, then regenerated.
public actor CachedTokenProvider {
    private let generator: AuthTokenGenerating
    private let safetyMargin: TimeInterval
    private let now: @Sendable () -> Date
    private var cache: [TokenRequest: AuthToken] = [:]
    private var inFlight: [TokenRequest: Task<AuthToken, Error>] = [:]
    private var listeners: [@Sendable (TokenEvent) -> Void] = []

    public init(
        generator: AuthTokenGenerating,
        safetyMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.generator = generator
        self.safetyMargin = safetyMargin
        self.now = now
    }

    public func onEvent(_ listener: @escaping @Sendable (TokenEvent) -> Void) {
        listeners.append(listener)
    }

    public func token(for request: TokenRequest) async throws -> AuthToken {
        if let cached = cache[request], cached.isUsable(at: now(), safetyMargin: safetyMargin) {
            notify(TokenEvent(request: request, token: cached, wasRefreshed: false))
            return cached
        }
        return try await refresh(request)
    }

    public func invalidate(_ request: TokenRequest) {
        cache[request] = nil
    }

    private func refresh(_ request: TokenRequest) async throws -> AuthToken {
        if let pending = inFlight[request] { return try await pending.value }
        let generator = self.generator
        let task = Task { try await generator.generateToken(for: request) }
        inFlight[request] = task
        defer { inFlight[request] = nil }
        let token = try await task.value
        cache[request] = token
        notify(TokenEvent(request: request, token: token, wasRefreshed: true))
        return token
    }

    private func notify(_ event: TokenEvent) {
        listeners.forEach { $0(event) }
    }
}
