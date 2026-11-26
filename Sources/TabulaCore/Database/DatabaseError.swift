import Foundation

public enum DatabaseError: Error, Equatable, LocalizedError {
    case connectionLost(String)
    case authenticationFailed(String)
    case server(message: String, detail: String?, hint: String?, sqlState: String?)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .connectionLost(let message): String(localized: "Connection lost: \(message)")
        case .authenticationFailed(let message): String(localized: "Authentication failed: \(message)")
        case .server(let message, let detail, let hint, let sqlState):
            [sqlState.map { "[\($0)] " + message } ?? message, detail.map { String(localized: "Detail: \($0)") }, hint.map { String(localized: "Hint: \($0)") }]
                .compactMap { $0 }
                .joined(separator: "\n")
        case .other(let message): message
        }
    }

    public var isConnectionLevel: Bool {
        switch self {
        case .connectionLost, .authenticationFailed: true
        case .server, .other: false
        }
    }
}
