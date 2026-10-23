import Foundation
import Testing
@testable import TabulaCore

struct TablePlusImporterTests {
    /// Same shape as a real TablePlus export, with made-up values.
    let export = """
        [{"Name": "Acme", "IsExpaned": 1, "groups": [
            {"Name": "Analytics", "connections": [
                {"ConnectionName": "dsql", "Driver": "PostgreSQL", "DatabaseHost": "abc.dsql.eu-west-1.on.aws",
                 "DatabaseUser": "admin", "DatabaseName": "", "Enviroment": "staging"}
            ], "groups": []}
          ],
          "connections": [
            {"ConnectionName": "app TEST", "Driver": "PostgreSQL", "DatabaseHost": "127.0.0.1", "DatabasePort": "15435",
             "DatabaseUser": "app", "DatabaseName": "", "DatabasePassword": "s3cret", "DatabasePasswordMode": 0,
             "Enviroment": "testing", "tLSMode": 0, "SafeModeLevel": 0, "isOverSSH": 0, "isUseSocket": 0},
            {"ConnectionName": "app PROD", "Driver": "PostgreSQL", "DatabaseHost": "db.internal", "DatabasePort": 5432,
             "DatabaseUser": "app", "DatabaseName": "main", "DatabasePassword": "x", "DatabasePasswordMode": 1,
             "Enviroment": "production", "tLSMode": 2, "SafeModeLevel": 4, "isOverSSH": 1,
             "ServerAddress": "1.2.3.4", "ServerUser": "ec2-user"},
            {"ConnectionName": "cache", "Driver": "Redis", "DatabaseHost": "127.0.0.1"}
          ]
        }]
        """

    @Test func readsEncryptedExports() throws {
        let encrypted = try RNCryptor.encrypt(Data(export.utf8), password: "pw", encryptionSalt: Array(1...8), hmacSalt: Array(2...9), iv: Array(3...18))
        let result = try TablePlusImporter.read(encrypted, password: "pw")
        #expect(result.connections.count == 3)
        #expect(throws: RNCryptor.Failure.wrongPassword) { try TablePlusImporter.read(encrypted, password: "nope") }
    }

    @Test func mapsPostgresFields() throws {
        let result = try TablePlusImporter.parse(json: Data(export.utf8))
        let test = try #require(result.connections.first { $0.connection.name == "app TEST" })
        #expect(test.connection.kind == .postgres(PostgresSettings(host: "127.0.0.1", port: 15435, user: "app", database: "", sslMode: .preferred, passwordStorage: .keychain)))
        #expect(test.connection.tag == .testing)
        #expect(test.connection.group == "Acme")
        #expect(test.password == "s3cret")
        #expect(test.warnings.isEmpty)
    }

    @Test func keepsSafetyTagsAndWarnsAboutSSH() throws {
        let prod = try #require(try TablePlusImporter.parse(json: Data(export.utf8)).connections.first { $0.connection.name == "app PROD" })
        #expect(prod.connection.tag == .production)
        #expect(prod.connection.safeMode == .alertWrites)
        #expect(prod.password == nil)
        if case .postgres(let settings) = prod.connection.kind {
            #expect(settings.sslMode == .required)
            #expect(settings.passwordStorage == .askEveryTime)
        }
        #expect(prod.warnings.first?.contains("ec2-user@1.2.3.4") == true)
    }

    @Test func dsqlHostsBecomeDSQLConnectionsInNestedGroups() throws {
        let dsql = try #require(try TablePlusImporter.parse(json: Data(export.utf8)).connections.first { $0.connection.name == "dsql" })
        #expect(dsql.connection.kind == .dsql(DSQLSettings(endpoint: "abc.dsql.eu-west-1.on.aws")))
        #expect(dsql.connection.group == "Acme / Analytics")
        #expect(dsql.password == nil)
    }

    @Test func skipsUnsupportedDrivers() throws {
        let result = try TablePlusImporter.parse(json: Data(export.utf8))
        #expect(result.skipped == [SkippedConnection(name: "cache", reason: "driver Redis non supportato")])
    }

    @Test func detectsSameServer() {
        let a = ConnectionConfig(name: "a", kind: .postgres(PostgresSettings(host: "h", port: 1, user: "u", database: "")))
        let b = ConnectionConfig(name: "b", kind: .postgres(PostgresSettings(host: "h", port: 1, user: "u", database: "")))
        let c = ConnectionConfig(name: "c", kind: .postgres(PostgresSettings(host: "h", port: 2, user: "u", database: "")))
        #expect(a.pointsToSameServer(as: b))
        #expect(!a.pointsToSameServer(as: c))
    }
}
