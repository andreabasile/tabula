import Foundation

/// A shell script run before connecting, typically to open a tunnel (SSM, SSH) whose
/// local end is the connection's host and port.
public struct PreConnectScript: Codable, Equatable, Sendable {
    public var script: String
    /// true: the script may keep running (a tunnel); Tabula waits until host:port accepts
    /// connections, and skips the script when it already does.
    /// false: the script must finish (exit 0) before connecting, and runs every time.
    public var waitsForPort: Bool
    public var timeoutSeconds: Int

    public init(script: String, waitsForPort: Bool = true, timeoutSeconds: Int = 30) {
        self.script = script
        self.waitsForPort = waitsForPort
        self.timeoutSeconds = timeoutSeconds
    }

    public var isEmpty: Bool { script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum PreConnectScriptError: Error, Equatable, LocalizedError {
    case scriptFailed(exitCode: Int32, output: String)
    case portNeverOpened(host: String, port: Int, seconds: Int, output: String)
    case scriptTimedOut(seconds: Int, output: String)

    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let code, let output):
            "Lo script prima della connessione è terminato con errore (\(code)).\(Self.tail(output))"
        case .portNeverOpened(let host, let port, let seconds, let output):
            "Dopo \(seconds) s \(host):\(port) non risponde ancora: il tunnel non si è aperto.\(Self.tail(output))"
        case .scriptTimedOut(let seconds, let output):
            "Lo script prima della connessione non è terminato entro \(seconds) s.\(Self.tail(output))"
        }
    }

    private static func tail(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).suffix(8)
        return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
    }
}
