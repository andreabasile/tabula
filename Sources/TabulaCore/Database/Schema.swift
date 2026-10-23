import Foundation

public enum TableKind: String, Sendable {
    case table, view, materializedView

    init(catalogType: String) {
        switch catalogType {
        case "VIEW": self = .view
        case "MATERIALIZED VIEW": self = .materializedView
        default: self = .table
        }
    }
}

public struct TableInfo: Equatable, Hashable, Identifiable, Sendable {
    public let reference: TableReference
    public let kind: TableKind

    public var id: TableReference { reference }
    public var name: String { reference.name }
}

public struct ColumnInfo: Equatable, Hashable, Identifiable, Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let defaultExpression: String?
    public let isPrimaryKey: Bool

    public var id: String { name }
}

public struct IndexInfo: Equatable, Hashable, Identifiable, Sendable {
    public let name: String
    public let definition: String

    public var id: String { name }
}

public struct TableStructure: Equatable, Sendable {
    public let columns: [ColumnInfo]
    public let indexes: [IndexInfo]

    public init(columns: [ColumnInfo], indexes: [IndexInfo]) {
        self.columns = columns
        self.indexes = indexes
    }

    public var primaryKey: [String] { columns.filter(\.isPrimaryKey).map(\.name) }
}

/// Catalog queries limited to what both PostgreSQL and Aurora DSQL expose.
public enum Introspection {
    public static let schemas = """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT IN ('pg_catalog', 'information_schema', 'sys')
          AND schema_name NOT LIKE 'pg\\_%'
        ORDER BY schema_name
        """

    public static let databases = """
        SELECT datname FROM pg_database
        WHERE NOT datistemplate AND datallowconn
        ORDER BY datname
        """

    public static func tables(schema: String) -> String {
        """
        SELECT table_name, table_type FROM information_schema.tables
        WHERE table_schema = \(SQLRendering.literal(.text(schema)))
        ORDER BY table_name
        """
    }

    public static func columns(_ table: TableReference) -> String {
        """
        SELECT c.column_name, c.data_type, c.is_nullable, c.column_default,
               CASE WHEN k.column_name IS NULL THEN 'NO' ELSE 'YES' END AS is_primary
        FROM information_schema.columns c
        LEFT JOIN (
            SELECT ku.column_name FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage ku
              ON ku.constraint_name = tc.constraint_name AND ku.table_schema = tc.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = \(SQLRendering.literal(.text(table.schema)))
              AND tc.table_name = \(SQLRendering.literal(.text(table.name)))
        ) k ON k.column_name = c.column_name
        WHERE c.table_schema = \(SQLRendering.literal(.text(table.schema)))
          AND c.table_name = \(SQLRendering.literal(.text(table.name)))
        ORDER BY c.ordinal_position
        """
    }

    public static func indexes(_ table: TableReference) -> String {
        """
        SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = \(SQLRendering.literal(.text(table.schema)))
          AND tablename = \(SQLRendering.literal(.text(table.name)))
        ORDER BY indexname
        """
    }

    public static func allColumns(schema: String) -> String {
        """
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = \(SQLRendering.literal(.text(schema)))
        ORDER BY table_name, ordinal_position
        """
    }

    public static func foreignKeys(schema: String) -> String {
        """
        SELECT kcu.table_name, kcu.column_name, ccu.table_name, ccu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema
        JOIN information_schema.constraint_column_usage ccu
          ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = \(SQLRendering.literal(.text(schema)))
        """
    }

    public static func parseCatalog(columns: QueryResult, foreignKeys: QueryResult?) -> SchemaCatalog {
        var byTable: [String: [String]] = [:]
        for row in columns.rows {
            guard row.count >= 2, let table = row[0].textValue, let column = row[1].textValue else { continue }
            byTable[table, default: []].append(column)
        }
        let keys = (foreignKeys?.rows ?? []).compactMap { row -> ForeignKey? in
            guard row.count >= 4, let table = row[0].textValue, let column = row[1].textValue,
                  let target = row[2].textValue, let targetColumn = row[3].textValue else { return nil }
            return ForeignKey(table: table, column: column, referencedTable: target, referencedColumn: targetColumn)
        }
        return SchemaCatalog(columns: byTable, foreignKeys: keys)
    }

    public static func parseTables(_ result: QueryResult, schema: String) -> [TableInfo] {
        result.rows.compactMap { row in
            guard let name = row.first?.textValue else { return nil }
            let type = row.count > 1 ? row[1].textValue ?? "" : ""
            return TableInfo(reference: TableReference(schema: schema, name: name), kind: TableKind(catalogType: type))
        }
    }

    public static func parseColumns(_ result: QueryResult) -> [ColumnInfo] {
        result.rows.compactMap { row in
            guard row.count >= 5, let name = row[0].textValue else { return nil }
            return ColumnInfo(
                name: name,
                dataType: row[1].textValue ?? "",
                isNullable: row[2].textValue == "YES",
                defaultExpression: row[3].textValue,
                isPrimaryKey: row[4].textValue == "YES"
            )
        }
    }

    public static func parseIndexes(_ result: QueryResult) -> [IndexInfo] {
        result.rows.compactMap { row in
            guard row.count >= 2, let name = row[0].textValue else { return nil }
            return IndexInfo(name: name, definition: row[1].textValue ?? "")
        }
    }
}
