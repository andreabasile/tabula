import Foundation

public struct ForeignKey: Equatable, Hashable, Sendable {
    public let table: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String

    public init(table: String, column: String, referencedTable: String, referencedColumn: String) {
        self.table = table
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
    }
}

/// What the editor knows about the current schema.
public struct SchemaCatalog: Equatable, Sendable {
    public var columns: [String: [String]]
    public var foreignKeys: [ForeignKey]

    public init(columns: [String: [String]] = [:], foreignKeys: [ForeignKey] = []) {
        self.columns = columns
        self.foreignKeys = foreignKeys
    }

    public var tables: [String] { columns.keys.sorted() }

    /// Declared foreign keys, plus `<name>_id → <name>.id` guesses for columns without
    /// one: Aurora DSQL has no foreign keys at all, and many schemas skip them.
    public var joinableKeys: [ForeignKey] {
        let declared = Set(foreignKeys.map { "\($0.table).\($0.column)" })
        let inferred = columns.flatMap { table, names in
            names.compactMap { column -> ForeignKey? in
                guard column.hasSuffix("_id"), !declared.contains("\(table).\(column)") else { return nil }
                let base = String(column.dropLast(3))
                guard let target = guessTable(for: base, excluding: table) else { return nil }
                return ForeignKey(table: table, column: column, referencedTable: target, referencedColumn: "id")
            }
        }
        return foreignKeys + inferred.sorted { ($0.table, $0.column) < ($1.table, $1.column) }
    }

    private func guessTable(for base: String, excluding table: String) -> String? {
        let candidates = [base, base + "s", base + "es", String(base.dropLast()) + "ies"]
        let exact = candidates.first { columns[$0]?.contains("id") == true && $0 != table }
        if let exact { return exact }
        // Django-style names: company_id → companies_company.
        return columns.keys.sorted().first { name in
            name != table && name.hasSuffix("_" + base) && columns[name]?.contains("id") == true
        }
    }
}

public struct CompletionItem: Equatable, Sendable {
    public enum Kind: Sendable { case join, table, column, keyword, function }

    public let label: String
    public let insertText: String
    public let kind: Kind
    public let detail: String

    public init(label: String, insertText: String, kind: Kind, detail: String = "") {
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.detail = detail
    }
}

public struct CompletionResult: Equatable, Sendable {
    /// UTF-16 range of the partial word the chosen item replaces.
    public let replacementRange: Range<Int>
    public let items: [CompletionItem]
}

/// Context-aware SQL completion in the spirit of TablePlus: tables after FROM/JOIN,
/// columns after `alias.`, whole JOIN … ON clauses derived from foreign keys.
public enum SQLCompleter {
    static let keywords = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE", "ILIKE", "BETWEEN", "EXISTS",
        "JOIN", "LEFT JOIN", "RIGHT JOIN", "INNER JOIN", "FULL JOIN", "CROSS JOIN", "ON", "USING", "AS",
        "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC", "DISTINCT", "UNION", "UNION ALL",
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH", "CASE", "WHEN", "THEN",
        "ELSE", "END", "BEGIN", "COMMIT", "ROLLBACK", "EXPLAIN", "EXPLAIN ANALYZE", "CREATE TABLE", "ALTER TABLE",
        "DROP TABLE", "CREATE INDEX", "TRUE", "FALSE",
    ]
    static let functions = [
        "count(*)", "count(", "sum(", "avg(", "min(", "max(", "coalesce(", "now()", "date_trunc(", "lower(",
        "upper(", "length(", "string_agg(", "array_agg(", "json_agg(", "jsonb_build_object(", "to_char(",
        "extract(", "cast(", "nullif(", "greatest(", "least(", "round(", "concat(",
    ]
    private static let tableKeywords: Set<String> = ["from", "join", "update", "into", "table"]
    private static let reserved: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "is", "null", "like", "ilike", "join", "left", "right",
        "inner", "outer", "full", "cross", "on", "using", "as", "group", "order", "by", "having", "limit", "offset",
        "union", "insert", "into", "values", "update", "set", "delete", "returning", "with", "case", "when", "then",
        "else", "end", "table", "lateral", "natural", "window", "fetch", "for",
    ]

    public static func complete(text: String, cursor: Int, catalog: SchemaCatalog) -> CompletionResult {
        let units = Array(text.utf16)
        let cursor = min(max(cursor, 0), units.count)
        let wordStart = scanBack(units, from: cursor, while: isIdentifier)
        let prefix = String(decoding: units[wordStart..<cursor], as: UTF16.self).replacingOccurrences(of: "\"", with: "")
        let range = wordStart..<cursor
        let statement = StatementSplitter.statement(in: text, at: cursor)?.text ?? text
        let references = tableReferences(in: statement, catalog: catalog)

        if wordStart > 0, units[wordStart - 1] == UInt16(UInt8(ascii: ".")) {
            let qualifierStart = scanBack(units, from: wordStart - 1, while: isIdentifier)
            let qualifier = String(decoding: units[qualifierStart..<(wordStart - 1)], as: UTF16.self).replacingOccurrences(of: "\"", with: "")
            return CompletionResult(replacementRange: range, items: columnsAfterQualifier(qualifier, prefix: prefix, references: references, catalog: catalog))
        }

        let before = String(decoding: units[..<wordStart], as: UTF16.self)
        let keyword = lastKeyword(in: before)
        let items: [CompletionItem]
        if let keyword, tableKeywords.contains(keyword), !endsAfterTableName(before) {
            let joins = keyword == "join" ? joinSuggestions(references: references, catalog: catalog) : []
            items = joins + tableItems(catalog) + keywordItems()
        } else {
            items = columnItems(references: references, catalog: catalog) + keywordItems() + functionItems() + tableItems(catalog)
        }
        return CompletionResult(replacementRange: range, items: rank(items, prefix: prefix))
    }

    // MARK: Query understanding

    struct TableReference: Equatable {
        let table: String
        let alias: String?
        var name: String { alias ?? table }
    }

    /// `FROM a x`, `JOIN b AS y`, `UPDATE c`… with their aliases, in order of appearance.
    static func tableReferences(in sql: String, catalog: SchemaCatalog) -> [TableReference] {
        let tokens = tokenize(StatementSplitter.strippingComments(sql))
        var references: [TableReference] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index].lowercased()
            let introducesTable = tableKeywords.contains(token) || (token == "," && isInFromList(tokens, before: index))
            index += 1
            guard introducesTable, index < tokens.count else { continue }
            var name = unquote(tokens[index])
            if index + 2 < tokens.count, tokens[index + 1] == "." {
                name = unquote(tokens[index + 2])
                index += 2
            }
            guard isIdentifierToken(tokens[index]), !reserved.contains(name.lowercased()) else { continue }
            index += 1
            var alias: String?
            if index < tokens.count, tokens[index].lowercased() == "as" { index += 1 }
            if index < tokens.count, isIdentifierToken(tokens[index]), !reserved.contains(tokens[index].lowercased()) {
                alias = unquote(tokens[index])
                index += 1
            }
            references.append(TableReference(table: name, alias: alias))
        }
        return references
    }

    private static func isInFromList(_ tokens: [String], before index: Int) -> Bool {
        for token in tokens[..<index].reversed() {
            let lowered = token.lowercased()
            if lowered == "from" { return true }
            if lowered == "as" { continue }
            if reserved.contains(lowered) || token == "(" || token == ")" { return false }
        }
        return false
    }

    private static func lastKeyword(in text: String) -> String? {
        let tokens = tokenize(StatementSplitter.strippingComments(text))
        for token in tokens.reversed() {
            let lowered = token.lowercased()
            if reserved.contains(lowered) { return lowered }
            if token == "," {
                return isInFromList(tokens, before: tokens.count) ? "from" : nil
            }
        }
        return nil
    }

    /// `FROM users |` or `FROM users u |`: a table is already there, so offer the next clause.
    private static func endsAfterTableName(_ text: String) -> Bool {
        guard text.last?.isWhitespace == true else { return false }
        let tokens = tokenize(StatementSplitter.strippingComments(text))
        guard let last = tokens.last else { return false }
        return isIdentifierToken(last) && !reserved.contains(last.lowercased())
    }

    // MARK: Suggestions

    private static func columnsAfterQualifier(_ qualifier: String, prefix: String, references: [TableReference], catalog: SchemaCatalog) -> [CompletionItem] {
        let table = references.first { $0.alias?.caseInsensitiveCompare(qualifier) == .orderedSame }?.table
            ?? references.first { $0.table.caseInsensitiveCompare(qualifier) == .orderedSame }?.table
            ?? qualifier
        let columns = catalog.columns[table] ?? []
        let items = columns.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .column, detail: table) }
        return rank(items, prefix: prefix)
    }

    private static func columnItems(references: [TableReference], catalog: SchemaCatalog) -> [CompletionItem] {
        let qualify = references.count > 1
        return references.flatMap { reference in
            (catalog.columns[reference.table] ?? []).map { column in
                CompletionItem(
                    label: qualify ? "\(reference.name).\(column)" : column,
                    insertText: qualify ? "\(quoteIfNeeded(reference.name)).\(quoteIfNeeded(column))" : quoteIfNeeded(column),
                    kind: .column,
                    detail: reference.table
                )
            }
        }
    }

    private static func tableItems(_ catalog: SchemaCatalog) -> [CompletionItem] {
        catalog.tables.map { CompletionItem(label: $0, insertText: quoteIfNeeded($0), kind: .table, detail: "tabella") }
    }

    private static func keywordItems() -> [CompletionItem] {
        keywords.map { CompletionItem(label: $0, insertText: $0, kind: .keyword) }
    }

    private static func functionItems() -> [CompletionItem] {
        functions.map { CompletionItem(label: $0, insertText: $0, kind: .function) }
    }

    /// For every table already in the query, the tables linked to it by a key, with the ON clause.
    static func joinSuggestions(references: [TableReference], catalog: SchemaCatalog) -> [CompletionItem] {
        var usedNames = Set(references.map { $0.name.lowercased() })
        var items: [CompletionItem] = []
        for reference in references {
            for key in catalog.joinableKeys {
                let link: (other: String, otherColumn: String, ownColumn: String)?
                if key.referencedTable == reference.table {
                    link = (key.table, key.column, key.referencedColumn)
                } else if key.table == reference.table {
                    link = (key.referencedTable, key.referencedColumn, key.column)
                } else {
                    link = nil
                }
                guard let link else { continue }
                let alias = uniqueAlias(for: link.other, used: usedNames)
                let condition = "\(quoteIfNeeded(alias)).\(quoteIfNeeded(link.otherColumn)) = \(quoteIfNeeded(reference.name)).\(quoteIfNeeded(link.ownColumn))"
                let text = "\(quoteIfNeeded(link.other)) \(alias) ON \(condition)"
                guard !items.contains(where: { $0.insertText == text }) else { continue }
                items.append(CompletionItem(label: text, insertText: text, kind: .join, detail: "join"))
            }
        }
        usedNames.removeAll()
        return items
    }

    /// `companies_office` → `co`; adds a digit when the alias is already taken.
    static func uniqueAlias(for table: String, used: Set<String>) -> String {
        let initials = table.split(separator: "_").compactMap(\.first).map(String.init).joined().lowercased()
        let base = initials.isEmpty ? "t" : initials
        let reservedBase = reserved.contains(base) ? base + "1" : base
        guard used.contains(reservedBase) else { return reservedBase }
        var counter = 2
        while used.contains("\(base)\(counter)") { counter += 1 }
        return "\(base)\(counter)"
    }

    private static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        guard !prefix.isEmpty else { return items }
        let lowered = prefix.lowercased()
        let starts = items.filter { item in
            item.label.lowercased().hasPrefix(lowered) || item.label.lowercased().split(separator: ".").last?.hasPrefix(lowered) == true
        }
        let contains = items.filter { $0.label.lowercased().contains(lowered) && !starts.contains($0) }
        return starts + contains
    }

    // MARK: Lexing helpers

    static func quoteIfNeeded(_ identifier: String) -> String {
        let isPlain = identifier.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil
        return isPlain && !reserved.contains(identifier) ? identifier : SQLRendering.identifier(identifier)
    }

    private static func unquote(_ token: String) -> String {
        token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 ? String(token.dropFirst().dropLast()) : token
    }

    private static func isIdentifierToken(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return first == "\"" || first == "_" || first.isLetter
    }

    private static func tokenize(_ sql: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var inString = false
        for character in sql {
            if inString {
                if character == "'" { inString = false }
                continue
            }
            if inQuotes {
                current.append(character)
                if character == "\"" {
                    tokens.append(current)
                    current = ""
                    inQuotes = false
                }
                continue
            }
            if character == "'" {
                flush(&current, into: &tokens)
                inString = true
            } else if character == "\"" {
                flush(&current, into: &tokens)
                current = "\""
                inQuotes = true
            } else if character.isLetter || character.isNumber || character == "_" || character == "$" {
                current.append(character)
            } else {
                flush(&current, into: &tokens)
                if !character.isWhitespace { tokens.append(String(character)) }
            }
        }
        flush(&current, into: &tokens)
        return tokens
    }

    private static func flush(_ current: inout String, into tokens: inout [String]) {
        if !current.isEmpty { tokens.append(current) }
        current = ""
    }

    private static func scanBack(_ units: [UInt16], from index: Int, while predicate: (UInt16) -> Bool) -> Int {
        var start = index
        while start > 0, predicate(units[start - 1]) { start -= 1 }
        return start
    }

    private static func isIdentifier(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == UInt16(UInt8(ascii: "_")) || unit == UInt16(UInt8(ascii: "\""))
    }
}
