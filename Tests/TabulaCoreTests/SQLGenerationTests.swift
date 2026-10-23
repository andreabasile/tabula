import Testing
@testable import TabulaCore

struct SQLRenderingTests {
    @Test func quotesIdentifiersAndLiterals() {
        #expect(SQLRendering.identifier(#"we"ird"#) == #""we""ird""#)
        #expect(SQLRendering.literal(.text("O'Hara")) == "'O''Hara'")
        #expect(SQLRendering.literal(.null) == "NULL")
        #expect(SQLRendering.equality(column: "a", value: .null) == #""a" IS NULL"#)
    }
}

struct ChangeSetTests {
    let table = TableReference(schema: "public", name: "users")

    @Test func generatesUpdatesKeyedByPrimaryKey() {
        var changes = ChangeSet()
        let key = ChangeSet.RowKey(["id": .text("7")])
        changes.setValue(.text("Ann"), column: "name", row: key)
        changes.setValue(.null, column: "email", row: key)
        #expect(changes.statements(for: table, columnOrder: ["id", "name", "email"]) == [
            #"UPDATE "public"."users" SET "name" = 'Ann', "email" = NULL WHERE "id" = '7';"#,
        ])
    }

    @Test func deletesComeFirstAndCancelPendingUpdates() {
        var changes = ChangeSet()
        let key = ChangeSet.RowKey(["id": .text("1")])
        changes.setValue(.text("x"), column: "name", row: key)
        changes.delete(key)
        #expect(changes.statements(for: table, columnOrder: []) == [#"DELETE FROM "public"."users" WHERE "id" = '1';"#])
        #expect(changes.count == 1)
    }

    @Test func insertsSkipDefaultColumns() {
        var changes = ChangeSet()
        changes.insert(["id": .defaultValue, "name": .text("Bo")])
        changes.insert(["id": .defaultValue])
        #expect(changes.statements(for: table, columnOrder: ["id", "name"]) == [
            #"INSERT INTO "public"."users" ("name") VALUES ('Bo');"#,
            #"INSERT INTO "public"."users" DEFAULT VALUES;"#,
        ])
    }

    @Test func compositeKeysAreSortedForStableOutput() {
        var changes = ChangeSet()
        changes.delete(.init(["b": .text("2"), "a": .text("1")]))
        #expect(changes.statements(for: table, columnOrder: []) == [
            #"DELETE FROM "public"."users" WHERE "a" = '1' AND "b" = '2';"#,
        ])
    }
}

struct TableQueryTests {
    let table = TableReference(schema: "app", name: "orders")

    @Test func plainPage() {
        let query = TableQuery(table: table, page: 2, pageSize: 100)
        #expect(query.selectSQL(columns: []) == #"SELECT * FROM "app"."orders" LIMIT 100 OFFSET 200"#)
    }

    @Test func filtersAndSort() {
        let query = TableQuery(
            table: table,
            filters: [ColumnFilter(column: "status", op: .equals, value: "paid"), ColumnFilter(column: "note", op: .contains, value: "50%")],
            sort: SortOrder(column: "created_at", ascending: false)
        )
        #expect(query.selectSQL(columns: []) == #"SELECT * FROM "app"."orders" WHERE "status" = 'paid' AND "note"::text ILIKE '%50\%%' ORDER BY "created_at" DESC LIMIT 300 OFFSET 0"#)
    }

    @Test func anyColumnFilterOrsAllColumns() {
        let filter = ColumnFilter(column: nil, op: .contains, value: "x")
        #expect(filter.condition(allColumns: ["a", "b"]) == #"("a"::text ILIKE '%x%' OR "b"::text ILIKE '%x%')"#)
    }

    @Test func emptyFilterValuesAreIgnored() {
        let query = TableQuery(table: table, filters: [ColumnFilter(column: "a", op: .equals, value: "")])
        #expect(query.countSQL(columns: ["a"]) == #"SELECT count(*) FROM "app"."orders""#)
        #expect(ColumnFilter(column: "a", op: .isNull, value: "").condition(allColumns: []) == #""a" IS NULL"#)
    }
}

struct RowCopyFormatterTests {
    let rows: [[CellValue]] = [[.text("1"), .text("a,\"b\"")], [.text("2"), .null]]
    let columns = ["id", "name"]

    @Test func csvQuotesWhenNeeded() {
        #expect(RowCopyFormatter.format(rows, columns: columns, as: .csvWithHeader) == "id,name\n1,\"a,\"\"b\"\"\"\n2,")
    }

    @Test func jsonUsesNullForNull() {
        let json = RowCopyFormatter.format(rows, columns: columns, as: .json)
        #expect(json.contains(#""name": null"#))
        #expect(json.contains(#""name": "a,\"b\"""#))
    }

    @Test func sqlInsert() {
        let sql = RowCopyFormatter.format([rows[1]], columns: columns, as: .sqlInsert, table: TableReference(schema: "s", name: "t"))
        #expect(sql == #"INSERT INTO "s"."t" ("id", "name") VALUES ('2', NULL);"#)
    }

    @Test func markdownEscapesPipes() {
        let markdown = RowCopyFormatter.format([[.text("a|b")]], columns: ["x"], as: .markdown)
        #expect(markdown == "| x |\n| --- |\n| a\\|b |")
    }
}
