import Foundation

/// The table a query result reads from, when its rows can be edited in place as TablePlus
/// allows: every base column comes from one table and the result includes its primary key.
public struct ResultSource: Equatable, Sendable {
    public let table: TableReference
    /// Result column index → table column name. Expressions and aliases of other tables are absent
    /// and stay read-only.
    public let columnNames: [Int: String]
    /// Primary key column → result column index.
    public let keyColumns: [String: Int]

    /// The one table the result's base columns come from; nil for joins and pure expressions.
    public static func candidateTable(of columns: [ResultColumn]) -> UInt32? {
        let tables = Set(columns.map(\.sourceTable).filter { $0 != 0 })
        return tables.count == 1 ? tables.first : nil
    }

    public static func resolve(
        columns: [ResultColumn],
        table: TableReference,
        oid: UInt32,
        attributes: [Int: String],
        primaryKey: [String]
    ) -> ResultSource? {
        guard !primaryKey.isEmpty else { return nil }
        var names: [Int: String] = [:]
        for (index, column) in columns.enumerated() where column.sourceTable == oid {
            if let name = attributes[column.sourceColumn] { names[index] = name }
        }
        var keys: [String: Int] = [:]
        for key in primaryKey {
            guard let index = names.filter({ $0.value == key }).keys.min() else { return nil }
            keys[key] = index
        }
        return ResultSource(table: table, columnNames: names, keyColumns: keys)
    }

    public func isEditable(column: Int) -> Bool {
        columnNames[column] != nil
    }

    public func rowKey(_ row: [CellValue]) -> ChangeSet.RowKey {
        ChangeSet.RowKey(keyColumns.mapValues { row[$0] })
    }

    public static func parseAttributes(_ result: QueryResult) -> [Int: String] {
        var attributes: [Int: String] = [:]
        for row in result.rows {
            guard row.count >= 2, let number = row[0].textValue.flatMap(Int.init), let name = row[1].textValue else { continue }
            attributes[number] = name
        }
        return attributes
    }
}
