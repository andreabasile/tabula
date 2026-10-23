import Foundation

public enum CellValue: Equatable, Hashable, Sendable {
    case null
    case text(String)
    /// The column's DEFAULT; only meaningful while editing.
    case defaultValue

    public var displayText: String {
        switch self {
        case .null: "NULL"
        case .text(let value): value
        case .defaultValue: "DEFAULT"
        }
    }

    public var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

public struct ResultColumn: Equatable, Hashable, Sendable {
    public let name: String
    public let typeName: String
    /// OID of the table the column is read from, 0 for expressions (libpq's PQftable).
    public let sourceTable: UInt32
    /// The column's attribute number in that table, 0 when unknown (PQftablecol).
    public let sourceColumn: Int

    public init(name: String, typeName: String, sourceTable: UInt32 = 0, sourceColumn: Int = 0) {
        self.name = name
        self.typeName = typeName
        self.sourceTable = sourceTable
        self.sourceColumn = sourceColumn
    }
}

public struct QueryResult: Equatable, Sendable {
    public let columns: [ResultColumn]
    public let rows: [[CellValue]]
    public let commandTag: String
    public let duration: TimeInterval

    public init(columns: [ResultColumn], rows: [[CellValue]], commandTag: String, duration: TimeInterval) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.duration = duration
    }

    public var returnsRows: Bool { !columns.isEmpty }
}
