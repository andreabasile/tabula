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

    init(imported: ConnectionURL.Parsed) {
        self.init()
        let config = ConnectionConfig(name: "", kind: imported.kind)
        self = ConnectionDraft(connection: config, password: imported.password)
        isNew = true
        name = config.host.split(separator: ".").first.map(String.init) ?? config.host
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Dai un nome alla connessione" }
        switch driver {
        case .postgres:
            if postgres.host.isEmpty { return "Indica l'host" }
            if Int(portText) == nil { return "Porta non valida" }
        case .dsql:
            if dsql.endpoint.isEmpty { return "Indica l'endpoint del cluster" }
            if dsql.resolvedRegion == nil { return "Regione non ricavabile dall'endpoint: indicala" }
            if !dsqlUsesAdmin, dsql.user.isEmpty { return "Indica il ruolo database" }
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
