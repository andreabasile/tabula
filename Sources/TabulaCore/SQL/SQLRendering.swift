import Foundation

public enum SQLRendering {
    public static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func qualified(schema: String, table: String) -> String {
        identifier(schema) + "." + identifier(table)
    }

    public static func literal(_ value: CellValue) -> String {
        switch value {
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        case .text(let text): "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }

    /// `col = value`, or `col IS NULL` since `= NULL` never matches.
    public static func equality(column: String, value: CellValue) -> String {
        value == .null ? "\(identifier(column)) IS NULL" : "\(identifier(column)) = \(literal(value))"
    }
}
