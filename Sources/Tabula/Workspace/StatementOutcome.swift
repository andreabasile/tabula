import Foundation
import Observation
import TabulaCore

/// One statement's result, filled chunk by chunk while the server streams it.
@MainActor
@Observable
final class StatementOutcome: Identifiable {
    let id = UUID()
    let statement: String
    let startedAt = Date()
    private(set) var columns: [ResultColumn] = []
    private(set) var rows: [[CellValue]] = []
    private(set) var commandTag = ""
    private(set) var duration: TimeInterval?
    private(set) var error: String?
    /// Bumped on every chunk so the grid knows to redraw.
    private(set) var revision = 0
    /// Set when the rows come from one table with its primary key: cells can then be edited.
    private(set) var source: ResultSource?
    private(set) var isCancelled = false
    private(set) var changes = ChangeSet()
    var editError: String?

    init(statement: String) {
        self.statement = statement
    }

    var isRunning: Bool { duration == nil && error == nil }
    var returnsRows: Bool { !columns.isEmpty }

    func append(_ chunk: ResultChunk) {
        guard !isCancelled else { return }
        if columns.isEmpty { columns = chunk.columns }
        rows.append(contentsOf: chunk.rows)
        revision += 1
    }

    func finish(_ summary: StreamSummary) {
        if columns.isEmpty { columns = summary.columns }
        commandTag = summary.commandTag
        duration = summary.duration
        revision += 1
    }

    func fail(_ message: String) {
        error = message
        duration = Date().timeIntervalSince(startedAt)
        revision += 1
    }

    func cancel() {
        guard isRunning else { return }
        isCancelled = true
        fail(String(localized: "Query cancelled"))
    }

    // MARK: Editing

    func setSource(_ source: ResultSource?) {
        self.source = source
        revision += 1
    }

    var isEditable: Bool { source != nil && !isRunning }

    func canEdit(column: Int) -> Bool { source?.isEditable(column: column) == true }

    func value(row: Int, column: Int) -> CellValue {
        if let source, let name = source.columnNames[column],
           let edited = changes.updates[source.rowKey(rows[row])]?[name] {
            return edited
        }
        return rows[row][column]
    }

    func state(row: Int, column: Int) -> CellState {
        guard let source else { return .normal }
        let key = source.rowKey(rows[row])
        if changes.deletes.contains(key) { return .deleted }
        guard let name = source.columnNames[column] else { return .normal }
        return changes.updates[key]?[name] != nil ? .edited : .normal
    }

    func setValue(_ value: CellValue, row: Int, column: Int) {
        guard let source, let name = source.columnNames[column], value != rows[row][column] else { return }
        changes.setValue(value, column: name, row: source.rowKey(rows[row]))
        revision += 1
    }

    func deleteRows(_ indexes: [Int]) {
        guard let source else { return }
        for row in indexes where rows.indices.contains(row) { changes.delete(source.rowKey(rows[row])) }
        revision += 1
    }

    func discardChanges() {
        changes = ChangeSet()
        editError = nil
        revision += 1
    }

    var pendingStatements: [String] {
        guard let source else { return [] }
        let order = source.columnNames.sorted { $0.key < $1.key }.map(\.value)
        return changes.statements(for: source.table, columnOrder: order)
    }

    /// After a successful commit the grid keeps the edited values instead of re-running the query.
    func applyCommittedChanges() {
        guard let source else { return }
        rows = rows.compactMap { row in
            let key = source.rowKey(row)
            if changes.deletes.contains(key) { return nil }
            guard let updates = changes.updates[key] else { return row }
            var patched = row
            for (index, name) in source.columnNames { if let value = updates[name] { patched[index] = value } }
            return patched
        }
        changes = ChangeSet()
        editError = nil
        revision += 1
    }
}
