import Foundation

public struct AuthToken: Equatable, Sendable {
    public let value: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(value: String, issuedAt: Date, expiresAt: Date) {
        self.value = value
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isUsable(at now: Date, safetyMargin: TimeInterval) -> Bool {
        now.addingTimeInterval(safetyMargin) < expiresAt
    }
}

public struct TokenRequest: Equatable, Hashable, Sendable {
    public let endpoint: String
    public let region: String
    public let awsProfile: String
    public let isAdmin: Bool
    public let lifetimeSeconds: Int

    public init(endpoint: String, region: String, awsProfile: String, isAdmin: Bool, lifetimeSeconds: Int) {
        self.endpoint = endpoint
        self.region = region
        self.awsProfile = awsProfile
        self.isAdmin = isAdmin
        self.lifetimeSeconds = lifetimeSeconds
    }

    public init(settings: DSQLSettings) throws {
        guard let region = settings.resolvedRegion else {
            throw DSQLConfigurationError.missingRegion(endpoint: settings.endpoint)
        }
        self.init(
            endpoint: settings.endpoint.trimmingCharacters(in: .whitespaces),
            region: region,
            awsProfile: settings.awsProfile.trimmingCharacters(in: .whitespaces),
            isAdmin: settings.isAdmin,
            lifetimeSeconds: settings.tokenLifetimeSeconds
        )
    }
}

public enum DSQLConfigurationError: Error, Equatable, LocalizedError {
    case missingRegion(endpoint: String)

    public var errorDescription: String? {
        switch self {
        case .missingRegion(let endpoint):
            "Impossibile ricavare la regione da \"\(endpoint)\": indicala a mano."
        }
    }
}

public protocol AuthTokenGenerating: Sendable {
    func generateToken(for request: TokenRequest) async throws -> AuthToken
}
