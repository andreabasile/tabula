import Foundation
import Observation
import TabulaCore

@MainActor
@Observable
final class AppModel {
    private(set) var connections: [ConnectionConfig] = []
    /// Workspace windows currently open, keyed by window target.
    private(set) var openWorkspaces: [UUID: WorkspaceModel] = [:]
    var loadError: String?

    let store: ConnectionStore
    let sessionFactory: SessionFactory

    init(store: ConnectionStore = ConnectionStore(fileURL: ConnectionStore.defaultFileURL(), secrets: KeychainSecretStore())) {
        self.store = store
        self.sessionFactory = SessionFactory(tokens: CachedTokenProvider(generator: AWSCLITokenGenerator()))
        reload()
    }

    func reload() {
        do {
            connections = try store.load().sorted { ($0.group, $0.name.lowercased()) < ($1.group, $1.name.lowercased()) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func connection(_ id: UUID) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    func save(_ connection: ConnectionConfig, password: String?) throws {
        try store.save(connection, password: password)
        reload()
    }

    func delete(_ id: UUID) throws {
        try store.delete(id)
        reload()
    }

    func duplicate(_ connection: ConnectionConfig) throws {
        var copy = connection
        copy.id = UUID()
        copy.name += " copia"
        try save(copy, password: try store.password(for: connection.id))
    }

    func register(_ workspace: WorkspaceModel, target: UUID) {
        openWorkspaces[target] = workspace
    }

    func unregister(target: UUID) {
        openWorkspaces[target] = nil
    }

    func isOpen(_ connectionID: UUID) -> Bool {
        openWorkspaces.values.contains { $0.connection.id == connectionID }
    }

    func savedPassword(for id: UUID) -> String? {
        try? store.password(for: id)
    }
}
