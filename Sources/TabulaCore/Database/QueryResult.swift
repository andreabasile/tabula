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

    public init(name: String, typeName: String) {
        self.name = name
        self.typeName = typeName
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
