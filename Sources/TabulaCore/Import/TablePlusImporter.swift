import Foundation

public struct ImportedConnection: Identifiable, Sendable {
    public let connection: ConnectionConfig
    public let password: String?
    public let warnings: [String]

    public var id: UUID { connection.id }
}

public struct SkippedConnection: Equatable, Sendable {
    public let name: String
    public let reason: String
}

public struct TablePlusImport: Sendable {
    public let connections: [ImportedConnection]
    public let skipped: [SkippedConnection]
}

/// Reads TablePlus's "Export Connections" file: an encrypted tree of groups, each with
/// `connections` and nested `groups`.
public enum TablePlusImporter {
    private static let postgresDrivers: Set<String> = ["PostgreSQL", "Greenplum", "CockroachDB", "Redshift"]

    public static func read(_ data: Data, password: String) throws -> TablePlusImport {
        let json = RNCryptor.isEncrypted(data) ? try RNCryptor.decrypt(data, password: password) : data
        return try parse(json: json)
    }

    public static func parse(json: Data) throws -> TablePlusImport {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [Any] else {
            throw RNCryptor.Failure.unknownFormat
        }
        var imported: [ImportedConnection] = []
        var skipped: [SkippedConnection] = []
        collect(root, groupPath: [], into: &imported, skipped: &skipped)
        return TablePlusImport(connections: imported, skipped: skipped)
    }

    private static func collect(_ nodes: [Any], groupPath: [String], into imported: inout [ImportedConnection], skipped: inout [SkippedConnection]) {
        for case let node as [String: Any] in nodes {
            if node["ConnectionName"] != nil || node["Driver"] != nil {
                convert(node, group: groupPath.joined(separator: " / "), into: &imported, skipped: &skipped)
                continue
            }
            let path = groupPath + [string(node["Name"])].filter { !$0.isEmpty }
            collect(node["connections"] as? [Any] ?? [], groupPath: path, into: &imported, skipped: &skipped)
            collect(node["groups"] as? [Any] ?? [], groupPath: path, into: &imported, skipped: &skipped)
        }
    }

    private static func convert(_ item: [String: Any], group: String, into imported: inout [ImportedConnection], skipped: inout [SkippedConnection]) {
        let name = string(item["ConnectionName"]).isEmpty ? "Senza nome" : string(item["ConnectionName"])
        let driver = string(item["Driver"])
        guard postgresDrivers.contains(driver) else {
            skipped.append(SkippedConnection(name: name, reason: "driver \(driver.isEmpty ? "sconosciuto" : driver) non supportato"))
            return
        }
        var warnings: [String] = []
        if bool(item["isOverSSH"]) {
            warnings.append("Usa un tunnel SSH (\(string(item["ServerUser"]))@\(string(item["ServerAddress"]))), che Tabula non gestisce ancora: aprilo a parte.")
        }
        let host = bool(item["isUseSocket"]) && !string(item["DatabaseSocket"]).isEmpty ? string(item["DatabaseSocket"]) : string(item["DatabaseHost"])
        let kind: ConnectionKind
        var password: String?
        if DSQLEndpoint.isDSQLHost(host) {
            kind = .dsql(DSQLSettings(endpoint: host, user: string(item["DatabaseUser"]).isEmpty ? DSQLSettings.adminRole : string(item["DatabaseUser"]), database: string(item["DatabaseName"]).isEmpty ? "postgres" : string(item["DatabaseName"])))
            warnings.append("Endpoint DSQL: scegli il profilo AWS nella modifica della connessione.")
        } else {
            let storage = passwordStorage(item["DatabasePasswordMode"])
            kind = .postgres(PostgresSettings(
                host: host,
                port: int(item["DatabasePort"]) ?? 5432,
                user: string(item["DatabaseUser"]),
                database: string(item["DatabaseName"]),
                sslMode: sslMode(item["tLSMode"]),
                passwordStorage: storage
            ))
            password = storage == .keychain ? nonEmpty(item["DatabasePassword"]) : nil
        }
        let connection = ConnectionConfig(
            name: name,
            tag: ConnectionTag(rawValue: string(item["Enviroment"]).lowercased()) ?? .local,
            group: group,
            kind: kind,
            safeMode: safeMode(item["SafeModeLevel"])
        )
        imported.append(ImportedConnection(connection: connection, password: password, warnings: warnings))
    }

    /// Order of TablePlus's SSL popup: PREFERRED, DISABLED, REQUIRED, ALLOW, VERIFY-CA, VERIFY-FULL.
    static func sslMode(_ value: Any?) -> SSLMode {
        switch int(value) ?? 0 {
        case 1: .disabled
        case 2, 4, 5: .required
        default: .preferred
        }
    }

    /// Order of TablePlus's password popup: keychain, ask every time, no password.
    static func passwordStorage(_ value: Any?) -> PasswordStorage {
        switch int(value) ?? 0 {
        case 1: .askEveryTime
        case 2: .none
        default: .keychain
        }
    }

    /// TablePlus levels: silent, alert 1, alert 2, safe 1, safe 2. Tabula has no password-gated
    /// "safe" levels, so those map to the matching alert level.
    static func safeMode(_ value: Any?) -> SafeMode {
        switch int(value) ?? 0 {
        case 1, 3: .alertAll
        case 2, 4: .alertWrites
        default: .silent
        }
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        let text = string(value)
        return text.isEmpty ? nil : text
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        (int(value) ?? 0) != 0
    }
}

extension ConnectionConfig {
    /// Same server, port, user and database: used to skip connections already imported.
    public func pointsToSameServer(as other: ConnectionConfig) -> Bool {
        guard host == other.host, user == other.user, database == other.database else { return false }
        switch (kind, other.kind) {
        case (.postgres(let lhs), .postgres(let rhs)): return lhs.port == rhs.port
        case (.dsql, .dsql): return true
        default: return false
        }
    }
}
