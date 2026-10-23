import Foundation

public enum RowCopyFormat: String, CaseIterable, Sendable {
    case plainText = "Testo semplice"
    case json = "JSON"
    case markdown = "Tabella Markdown"
    case csv = "CSV"
    case csvWithHeader = "CSV con intestazioni"
    case sqlInsert = "INSERT SQL"
}

/// The "Copy Rows As" menu of the result grid.
public enum RowCopyFormatter {
    public static func format(
        _ rows: [[CellValue]],
        columns: [String],
        as format: RowCopyFormat,
        table: TableReference? = nil
    ) -> String {
        switch format {
        case .plainText: rows.map { $0.map(\.displayText).joined(separator: "\t") }.joined(separator: "\n")
        case .json: json(rows, columns: columns)
        case .markdown: markdown(rows, columns: columns)
        case .csv: csv(rows)
        case .csvWithHeader: csv([columns.map(CellValue.text)] + rows)
        case .sqlInsert: sqlInsert(rows, columns: columns, table: table)
        }
    }

    private static func json(_ rows: [[CellValue]], columns: [String]) -> String {
        let objects = rows.map { row in
            let fields = zip(columns, row).map { "    \(jsonString($0)): \(jsonValue($1))" }
            return "  {\n" + fields.joined(separator: ",\n") + "\n  }"
        }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    private static func jsonValue(_ value: CellValue) -> String {
        guard case .text(let text) = value else { return "null" }
        return jsonString(text)
    }

    private static func jsonString(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func markdown(_ rows: [[CellValue]], columns: [String]) -> String {
        let escape = { (text: String) in text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        let header = "| " + columns.map(escape).joined(separator: " | ") + " |"
        let divider = "| " + columns.map { _ in "---" }.joined(separator: " | ") + " |"
        let body = rows.map { "| " + $0.map { escape($0.displayText) }.joined(separator: " | ") + " |" }
        return ([header, divider] + body).joined(separator: "\n")
    }

    private static func csv(_ rows: [[CellValue]]) -> String {
        rows.map { row in row.map(csvField).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func csvField(_ value: CellValue) -> String {
        guard case .text(let text) = value else { return "" }
        let needsQuoting = text.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        return needsQuoting ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    private static func sqlInsert(_ rows: [[CellValue]], columns: [String], table: TableReference?) -> String {
        let target = table?.qualifiedName ?? SQLRendering.identifier("table")
        let names = columns.map(SQLRendering.identifier).joined(separator: ", ")
        return rows.map { row in
            "INSERT INTO \(target) (\(names)) VALUES (\(row.map(SQLRendering.literal).joined(separator: ", ")));"
        }.joined(separator: "\n")
    }
}
