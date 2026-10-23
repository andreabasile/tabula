import Foundation

public protocol SecretStoring: Sendable {
    func password(for connectionID: UUID) throws -> String?
    func setPassword(_ password: String?, for connectionID: UUID) throws
}

/// Saved connections as JSON; passwords never touch the file, they go to a SecretStoring.
public final class ConnectionStore: @unchecked Sendable {
    private let fileURL: URL
    private let secrets: SecretStoring
    private let lock = NSLock()

    public init(fileURL: URL, secrets: SecretStoring) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    /// TABULA_CONNECTIONS_FILE points the app at another file, e.g. for UI checks.
    public static func defaultFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["TABULA_CONNECTIONS_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tabula", isDirectory: true).appendingPathComponent("connections.json")
    }

    public func load() throws -> [ConnectionConfig] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            return try JSONDecoder().decode([ConnectionConfig].self, from: Data(contentsOf: fileURL))
        }
    }

    public func save(_ connection: ConnectionConfig, password: String?) throws {
        var all = try load()
        if let index = all.firstIndex(where: { $0.id == connection.id }) {
            all[index] = connection
        } else {
            all.append(connection)
        }
        try write(all)
        if case .postgres(let settings) = connection.kind {
            try secrets.setPassword(settings.passwordStorage == .keychain ? password : nil, for: connection.id)
        }
    }

    public func delete(_ id: UUID) throws {
        try write(try load().filter { $0.id != id })
        try secrets.setPassword(nil, for: id)
    }

    public func password(for id: UUID) throws -> String? {
        try secrets.password(for: id)
    }

    private func write(_ connections: [ConnectionConfig]) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(connections).write(to: fileURL, options: .atomic)
        }
    }
}
