import Foundation

public struct TableReference: Equatable, Hashable, Sendable {
    public let schema: String
    public let name: String

    public init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }

    public var qualifiedName: String { SQLRendering.qualified(schema: schema, table: name) }
}

/// Pending edits on a table, committed together like TablePlus's ⌘S.
public struct ChangeSet: Equatable, Sendable {
    public struct RowKey: Equatable, Hashable, Sendable {
        public let values: [String: CellValue]

        public init(_ values: [String: CellValue]) {
            self.values = values
        }
    }

    public private(set) var updates: [RowKey: [String: CellValue]] = [:]
    public private(set) var updateOrder: [RowKey] = []
    public private(set) var inserts: [[String: CellValue]] = []
    public private(set) var deletes: [RowKey] = []

    public init() {}

    public var isEmpty: Bool { updates.isEmpty && inserts.isEmpty && deletes.isEmpty }
    public var count: Int { updates.count + inserts.count + deletes.count }

    public mutating func setValue(_ value: CellValue, column: String, row key: RowKey) {
        if updates[key] == nil { updateOrder.append(key) }
        updates[key, default: [:]][column] = value
    }

    public mutating func insert(_ row: [String: CellValue]) {
        inserts.append(row)
    }

    public mutating func updateInsertedValue(_ value: CellValue, column: String, at index: Int) {
        guard inserts.indices.contains(index) else { return }
        inserts[index][column] = value
    }

    public mutating func removeInsert(at index: Int) {
        guard inserts.indices.contains(index) else { return }
        inserts.remove(at: index)
    }

    public mutating func delete(_ key: RowKey) {
        updates[key] = nil
        updateOrder.removeAll { $0 == key }
        if !deletes.contains(key) { deletes.append(key) }
    }

    public mutating func undoDelete(_ key: RowKey) {
        deletes.removeAll { $0 == key }
    }

    public func statements(for table: TableReference, columnOrder: [String]) -> [String] {
        deleteStatements(table) + updateStatements(table, columnOrder: columnOrder) + insertStatements(table, columnOrder: columnOrder)
    }

    private func deleteStatements(_ table: TableReference) -> [String] {
        deletes.map { "DELETE FROM \(table.qualifiedName) WHERE \(whereClause($0));" }
    }

    private func updateStatements(_ table: TableReference, columnOrder: [String]) -> [String] {
        updateOrder.compactMap { key in
            guard let changes = updates[key], !changes.isEmpty else { return nil }
            let assignments = ordered(changes.keys, by: columnOrder)
                .map { "\(SQLRendering.identifier($0)) = \(SQLRendering.literal(changes[$0]!))" }
                .joined(separator: ", ")
            return "UPDATE \(table.qualifiedName) SET \(assignments) WHERE \(whereClause(key));"
        }
    }

    private func insertStatements(_ table: TableReference, columnOrder: [String]) -> [String] {
        inserts.map { row in
            let columns = ordered(row.keys, by: columnOrder).filter { row[$0] != .defaultValue }
            guard !columns.isEmpty else { return "INSERT INTO \(table.qualifiedName) DEFAULT VALUES;" }
            let names = columns.map(SQLRendering.identifier).joined(separator: ", ")
            let values = columns.map { SQLRendering.literal(row[$0]!) }.joined(separator: ", ")
            return "INSERT INTO \(table.qualifiedName) (\(names)) VALUES (\(values));"
        }
    }

    private func whereClause(_ key: RowKey) -> String {
        key.values.keys.sorted()
            .map { SQLRendering.equality(column: $0, value: key.values[$0]!) }
            .joined(separator: " AND ")
    }

    private func ordered(_ columns: Dictionary<String, CellValue>.Keys, by order: [String]) -> [String] {
        columns.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }
}
