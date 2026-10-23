import Testing
@testable import TabulaCore

struct SQLCompleterTests {
    let catalog = SchemaCatalog(
        columns: [
            "companies_company": ["id", "name", "vat"],
            "companies_office": ["id", "company_id", "city"],
            "users": ["id", "email", "company_id"],
        ],
        foreignKeys: [ForeignKey(table: "companies_office", column: "company_id", referencedTable: "companies_company", referencedColumn: "id")]
    )

    func complete(_ textWithCursor: String) -> CompletionResult {
        let cursor = textWithCursor.utf16.distance(from: textWithCursor.utf16.startIndex, to: textWithCursor.range(of: "|")!.lowerBound.samePosition(in: textWithCursor.utf16)!)
        return SQLCompleter.complete(text: textWithCursor.replacingOccurrences(of: "|", with: ""), cursor: cursor, catalog: catalog)
    }

    @Test func tablesAfterFrom() {
        let result = complete("SELECT * FROM comp|")
        #expect(result.items.first?.kind == .table)
        #expect(result.items.prefix(2).map(\.label) == ["companies_company", "companies_office"])
        #expect(result.replacementRange == 14..<18)
    }

    @Test func columnsAfterAlias() {
        let result = complete("SELECT c.| FROM companies_company c")
        #expect(result.items.map(\.label) == ["id", "name", "vat"])
    }

    @Test func columnsAfterAliasFilteredByPrefix() {
        #expect(complete("SELECT * FROM companies_office AS o WHERE o.ci|").items.map(\.label) == ["city"])
    }

    @Test func columnsOfTablesInQueryBeforeKeywords() {
        let result = complete("SELECT na| FROM companies_company")
        #expect(result.items.first == CompletionItem(label: "name", insertText: "name", kind: .column, detail: "companies_company"))
    }

    @Test func joinSuggestsTablesWithOnClauseFromForeignKeys() {
        let result = complete("SELECT * FROM companies_company c JOIN |")
        #expect(result.items.first?.kind == .join)
        #expect(result.items.first?.insertText == "companies_office co ON co.company_id = c.id")
    }

    @Test func joinUsesInferredKeysWhenNoneDeclared() {
        let result = complete("SELECT * FROM users u JOIN |")
        #expect(result.items.contains { $0.insertText == "companies_company cc ON cc.id = u.company_id" })
    }

    @Test func joinFilteredByPrefixAndAliasesStayUnique() {
        let result = complete("SELECT * FROM companies_office co JOIN companies_company c ON c.id = co.company_id JOIN us|")
        #expect(result.items.first?.insertText == "users u ON u.company_id = c.id")
    }

    @Test func afterTableNameOffersKeywordsNotTables() {
        let result = complete("SELECT * FROM users u WH|")
        #expect(result.items.first?.label == "WHERE")
    }

    @Test func qualifiesColumnsWhenSeveralTables() {
        let result = complete("SELECT ci| FROM companies_company c JOIN companies_office o ON o.company_id = c.id")
        #expect(result.items.first?.label == "o.city")
    }

    @Test func quotesIdentifiersThatNeedIt() {
        #expect(SQLCompleter.quoteIfNeeded("orderItems") == #""orderItems""#)
        #expect(SQLCompleter.quoteIfNeeded("order") == #""order""#)
        #expect(SQLCompleter.quoteIfNeeded("company_id") == "company_id")
    }

    @Test func parsesSchemaQualifiedAndQuotedTables() {
        let refs = SQLCompleter.tableReferences(in: #"SELECT * FROM public."users" AS u, companies_company"#, catalog: catalog)
        #expect(refs == [.init(table: "users", alias: "u"), .init(table: "companies_company", alias: nil)])
    }

    @Test func djangoStyleInference() {
        let keys = catalog.joinableKeys
        #expect(keys.contains(ForeignKey(table: "users", column: "company_id", referencedTable: "companies_company", referencedColumn: "id")))
        #expect(keys.filter { $0.table == "companies_office" && $0.column == "company_id" }.count == 1)
    }
}

struct CatalogParsingTests {
    @Test func groupsColumnsByTableAndReadsKeys() {
        let columns = QueryResult(columns: [], rows: [[.text("a"), .text("id")], [.text("a"), .text("b_id")], [.text("b"), .text("id")]], commandTag: "", duration: 0)
        let keys = QueryResult(columns: [], rows: [[.text("a"), .text("b_id"), .text("b"), .text("id")]], commandTag: "", duration: 0)
        let catalog = Introspection.parseCatalog(columns: columns, foreignKeys: keys)
        #expect(catalog.columns == ["a": ["id", "b_id"], "b": ["id"]])
        #expect(catalog.foreignKeys == [ForeignKey(table: "a", column: "b_id", referencedTable: "b", referencedColumn: "id")])
    }
}
