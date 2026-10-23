import Foundation

public enum DatabaseError: Error, Equatable, LocalizedError {
    case connectionLost(String)
    case authenticationFailed(String)
    case server(message: String, detail: String?, hint: String?, sqlState: String?)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .connectionLost(let message): "Connessione persa: \(message)"
        case .authenticationFailed(let message): "Autenticazione fallita: \(message)"
        case .server(let message, let detail, let hint, let sqlState):
            [sqlState.map { "[\($0)] " + message } ?? message, detail.map { "Dettaglio: \($0)" }, hint.map { "Suggerimento: \($0)" }]
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
