import Testing
@testable import TabulaCore

struct ResultSourceTests {
    let users = TableReference(schema: "public", name: "users")
    let attributes = [1: "id", 2: "email", 3: "name"]

    @Test func singleTableWithKeyIsEditable() throws {
        let columns = [
            ResultColumn(name: "id", typeName: "int4", sourceTable: 42, sourceColumn: 1),
            ResultColumn(name: "mail", typeName: "text", sourceTable: 42, sourceColumn: 2),
            ResultColumn(name: "upper", typeName: "text"),
        ]
        #expect(ResultSource.candidateTable(of: columns) == 42)
        let source = try #require(ResultSource.resolve(columns: columns, table: users, oid: 42, attributes: attributes, primaryKey: ["id"]))
        // The alias "mail" maps back to the real column; the expression stays read-only.
        #expect(source.columnNames == [0: "id", 1: "email"])
        #expect(!source.isEditable(column: 2))
        #expect(source.rowKey([.text("7"), .text("a@b.c"), .null]) == ChangeSet.RowKey(["id": .text("7")]))
    }

    @Test func joinsAreReadOnly() {
        let columns = [
            ResultColumn(name: "id", typeName: "int4", sourceTable: 42, sourceColumn: 1),
            ResultColumn(name: "total", typeName: "int4", sourceTable: 43, sourceColumn: 2),
        ]
        #expect(ResultSource.candidateTable(of: columns) == nil)
    }

    @Test func missingPrimaryKeyIsReadOnly() {
        let columns = [ResultColumn(name: "email", typeName: "text", sourceTable: 42, sourceColumn: 2)]
        #expect(ResultSource.resolve(columns: columns, table: users, oid: 42, attributes: attributes, primaryKey: ["id"]) == nil)
        #expect(ResultSource.resolve(columns: columns, table: users, oid: 42, attributes: attributes, primaryKey: []) == nil)
    }

    @Test func expressionsOnlyHaveNoTable() {
        #expect(ResultSource.candidateTable(of: [ResultColumn(name: "?column?", typeName: "int4")]) == nil)
    }

    @Test func parsesAttributes() {
        let result = QueryResult(columns: [], rows: [[.text("1"), .text("id")], [.text("3"), .text("name")]], commandTag: "", duration: 0)
        #expect(ResultSource.parseAttributes(result) == [1: "id", 3: "name"])
    }
}
