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
    public enum Failure: Error, Equatable, LocalizedError {
        case notAnExport

        public var errorDescription: String? {
            String(localized: "This file is not a TablePlus connection export.")
        }
    }

    private static let postgresDrivers: Set<String> = ["PostgreSQL", "Greenplum", "CockroachDB", "Redshift"]

    public static func read(_ data: Data, password: String) throws -> TablePlusImport {
        let json = RNCryptor.isEncrypted(data) ? try RNCryptor.decrypt(data, password: password) : data
        return try parse(json: json)
    }

    public static func parse(json: Data) throws -> TablePlusImport {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [Any] else {
            throw Failure.notAnExport
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
        let name = string(item["ConnectionName"]).isEmpty ? String(localized: "Untitled") : string(item["ConnectionName"])
        let driver = string(item["Driver"])
        guard postgresDrivers.contains(driver) else {
            let reason = driver.isEmpty ? String(localized: "unknown driver not supported") : String(localized: "unsupported driver \(driver)")
            skipped.append(SkippedConnection(name: name, reason: reason))
            return
        }
        var warnings: [String] = []
        if bool(item["isOverSSH"]) {
            warnings.append(String(localized: "Uses an SSH tunnel (\(string(item["ServerUser"]))@\(string(item["ServerAddress"]))), which Tabula doesn’t manage yet: open it separately."))
        }
        let host = bool(item["isUseSocket"]) && !string(item["DatabaseSocket"]).isEmpty ? string(item["DatabaseSocket"]) : string(item["DatabaseHost"])
        let kind: ConnectionKind
        var password: String?
        if DSQLEndpoint.isDSQLHost(host) {
            kind = .dsql(DSQLSettings(endpoint: host, userOrDefault: string(item["DatabaseUser"]), databaseOrDefault: string(item["DatabaseName"])))
            warnings.append(String(localized: "DSQL endpoint: choose the AWS profile when editing the connection."))
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
            if [4, 5].contains(int(item["tLSMode"])) { warnings.append(SSLMode.unverifiedCertificateWarning) }
        }
        let startupScript = string(item["StartupBashScript"])
        if let firstLine = startupScript.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }) {
            // It runs in a shell on every connect: an export from someone else must not run it unseen.
            warnings.append(String(localized: "Runs a shell script before connecting. Review it before you connect: \(String(firstLine))"))
        }
        let connection = ConnectionConfig(
            name: name,
            tag: ConnectionTag(rawValue: string(item["Enviroment"]).lowercased()) ?? .local,
            group: group,
            kind: kind,
            safeMode: safeMode(item["SafeModeLevel"]),
            preConnectScript: startupScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : PreConnectScript(script: startupScript)
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
