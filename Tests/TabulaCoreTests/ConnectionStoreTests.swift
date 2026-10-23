import Foundation
import Testing
@testable import TabulaCore

struct ConnectionStoreTests {
    func makeStore() -> (ConnectionStore, InMemorySecrets) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-\(UUID().uuidString)/connections.json")
        let secrets = InMemorySecrets()
        return (ConnectionStore(fileURL: url, secrets: secrets), secrets)
    }

    @Test func roundTripsBothKinds() throws {
        let (store, _) = makeStore()
        let postgres = ConnectionConfig(name: "local", kind: .postgres(PostgresSettings(user: "me", database: "app")))
        let dsql = ConnectionConfig(name: "prod", tag: .production, kind: .dsql(DSQLSettings(endpoint: "x.dsql.eu-west-1.on.aws", awsProfile: "dev")))
        try store.save(postgres, password: "secret")
        try store.save(dsql, password: nil)
        #expect(try store.load() == [postgres, dsql])
    }

    @Test func passwordGoesToSecretsNotFile() throws {
        let (store, secrets) = makeStore()
        let connection = ConnectionConfig(name: "local", kind: .postgres(PostgresSettings()))
        try store.save(connection, password: "hunter2")
        #expect(secrets.values[connection.id] == "hunter2")
        try store.delete(connection.id)
        #expect(secrets.values[connection.id] == nil)
        #expect(try store.load().isEmpty)
    }

    @Test func passwordIsDroppedWhenNotStoredInKeychain() throws {
        let (store, secrets) = makeStore()
        let connection = ConnectionConfig(name: "ask", kind: .postgres(PostgresSettings(passwordStorage: .askEveryTime)))
        try store.save(connection, password: "x")
        #expect(secrets.values[connection.id] == nil)
    }

    @Test func savingExistingIDReplacesIt() throws {
        let (store, _) = makeStore()
        var connection = ConnectionConfig(name: "a", kind: .postgres(PostgresSettings()))
        try store.save(connection, password: nil)
        connection.name = "b"
        try store.save(connection, password: nil)
        #expect(try store.load().map(\.name) == ["b"])
    }
}

struct AWSProfilesTests {
    @Test func readsProfilesFromBothFiles() {
        #expect(AWSProfiles.parse(config: "[default]\nregion=x\n[profile dev]\n[sso-session s]") == ["default", "dev"])
        #expect(AWSProfiles.parse(credentials: "[default]\n[old]") == ["default", "old"])
    }
}

final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    var values: [UUID: String] = [:]
    func password(for connectionID: UUID) throws -> String? { values[connectionID] }
    func setPassword(_ password: String?, for connectionID: UUID) throws { values[connectionID] = password }
}

struct ConnectionURLTests {
    @Test func parsesPostgresURL() {
        let parsed = ConnectionURL.parse("postgresql://me:p%40ss@db.example.com:6543/app?sslmode=require")
        #expect(parsed == .init(kind: .postgres(PostgresSettings(host: "db.example.com", port: 6543, user: "me", database: "app", sslMode: .required)), password: "p@ss"))
    }

    @Test func dsqlHostBecomesDSQLConnection() {
        let parsed = ConnectionURL.parse("postgres://admin@abc.dsql.eu-west-1.on.aws/postgres")
        #expect(parsed?.kind == .dsql(DSQLSettings(endpoint: "abc.dsql.eu-west-1.on.aws")))
        #expect(parsed?.password == nil)
    }

    @Test func rejectsOtherSchemes() {
        #expect(ConnectionURL.parse("mysql://x@y/z") == nil)
    }

    @Test func formatsWithoutPassword() {
        let connection = ConnectionConfig(name: "x", kind: .postgres(PostgresSettings(host: "h", port: 5433, user: "u", database: "d")))
        #expect(ConnectionURL.format(connection) == "postgresql://u@h:5433/d?sslmode=prefer")
    }
}
