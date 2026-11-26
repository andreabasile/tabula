import Foundation
import TabulaCore

enum Driver: String, CaseIterable, Identifiable {
    case postgres = "PostgreSQL"
    case dsql = "Amazon Aurora DSQL"

    var id: String { rawValue }
}

/// Form state for both drivers, so switching driver keeps what was typed.
struct ConnectionDraft: Identifiable {
    let id: UUID
    var isNew: Bool
    var name = ""
    var tag: ConnectionTag = .local
    var group = ""
    var safeMode: SafeMode = .silent
    var driver: Driver = .postgres
    var postgres = PostgresSettings()
    var portText = "5432"
    var password = ""
    /// The saved password could not be read (e.g. Keychain access denied): an empty field keeps it.
    var passwordUnreadable = false
    var dsql = DSQLSettings()
    var dsqlUsesAdmin = true
    var script = PreConnectScript(script: "")

    init() {
        id = UUID()
        isNew = true
    }

    init(connection: ConnectionConfig, password: String?) {
        id = connection.id
        isNew = false
        name = connection.name
        tag = connection.tag
        group = connection.group
        safeMode = connection.safeMode
        script = connection.preConnectScript ?? PreConnectScript(script: "")
        switch connection.kind {
        case .postgres(let settings):
            driver = .postgres
            postgres = settings
            portText = String(settings.port)
            self.password = password ?? ""
        case .dsql(let settings):
            driver = .dsql
            dsql = settings
            dsqlUsesAdmin = settings.isAdmin
        }
    }

    init(connection: ConnectionConfig, readPassword: () throws -> String?) {
        do {
            self = ConnectionDraft(connection: connection, password: try readPassword())
        } catch {
            self = ConnectionDraft(connection: connection, password: nil)
            passwordUnreadable = true
        }
    }

    init(imported: ConnectionURL.Parsed) {
        let config = ConnectionConfig(name: "", kind: imported.kind)
        self.init(connection: config, password: imported.password)
        isNew = true
        name = config.host.split(separator: ".").first.map(String.init) ?? config.host
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Name the connection") }
        switch driver {
        case .postgres:
            if postgres.host.isEmpty { return String(localized: "Enter the host") }
            if Int(portText) == nil { return String(localized: "Invalid port") }
        case .dsql:
            if dsql.endpoint.isEmpty { return String(localized: "Enter the cluster endpoint") }
            if dsql.resolvedRegion == nil { return String(localized: "Can’t determine the region from the endpoint: enter it") }
            if !dsqlUsesAdmin, dsql.user.isEmpty { return String(localized: "Enter the database role") }
        }
        return nil
    }

    func makeConnection() -> ConnectionConfig {
        ConnectionConfig(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            tag: tag,
            group: group.trimmingCharacters(in: .whitespaces),
            kind: kind,
            safeMode: safeMode,
            preConnectScript: script.isEmpty ? nil : script
        )
    }

    private var kind: ConnectionKind {
        switch driver {
        case .postgres:
            var settings = postgres
            settings.port = Int(portText) ?? 5432
            return .postgres(settings)
        case .dsql:
            var settings = dsql
            if dsqlUsesAdmin { settings.user = DSQLSettings.adminRole }
            return .dsql(settings)
        }
    }
}
