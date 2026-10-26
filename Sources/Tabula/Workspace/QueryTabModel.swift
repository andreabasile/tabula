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
    private(set) var changes = ChangeSet()
    var editError: String?

    init(statement: String) {
        self.statement = statement
    }

    var isRunning: Bool { duration == nil && error == nil }
    var returnsRows: Bool { !columns.isEmpty }

    func append(_ chunk: ResultChunk) {
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

@MainActor
@Observable
final class QueryTabModel {
    let id = UUID()
    var title: String
    var text: String
    /// UTF-16 range of the editor selection, for "run current/selected".
    var selection = NSRange(location: 0, length: 0)
    private(set) var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    private(set) var isRunning = false
    var selectedRows = IndexSet()
    /// TablePlus's "No limit / 100 / 300 …" popup; 0 means no limit.
    var rowLimit = 0
    var resultSearch = ""

    private unowned let workspace: WorkspaceModel

    init(title: String, text: String, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        self.workspace = workspace
    }

    var catalog: SchemaCatalog { workspace.catalog }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    /// "line 2, column 15, location 23", as in TablePlus's editor footer.
    var cursorDescription: String {
        let units = text.utf16Units
        let location = min(selection.location, units.count)
        var line = 1
        var lineStart = 0
        var offset = 0
        for unit in units[..<location] {
            offset += 1
            if unit == 0x0A { line += 1; lineStart = offset }
        }
        return "riga \(line), colonna \(location - lineStart + 1), posizione \(location)"
    }

    /// Indexes of the rows matching the result search box.
    func visibleRows(of outcome: StatementOutcome) -> [Int] {
        let query = resultSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return Array(outcome.rows.indices) }
        return outcome.rows.indices.filter { index in
            outcome.rows[index].contains { $0.textValue?.localizedCaseInsensitiveContains(query) == true }
        }
    }

    // MARK: Running

    /// ⌘↩: the selection if there is one, otherwise the statement under the cursor.
    func runCurrent() async {
        if selection.length > 0, let range = Range(selection, in: text) {
            await run(StatementSplitter.split(String(text[range])).map(\.text))
        } else if let statement = StatementSplitter.statement(in: text, at: selection.location) {
            await run([statement.text])
        }
    }

    func runAll() async {
        await run(StatementSplitter.split(text).map(\.text))
    }

    func cancel() {
        workspace.cancelRunningQuery()
    }

    /// ⌘I: formats the selection, or the whole editor when nothing is selected.
    func beautify() {
        if selection.length > 0, let range = Range(selection, in: text) {
            text.replaceSubrange(range, with: SQLBeautifier.format(String(text[range])))
        } else {
            text = SQLBeautifier.format(text)
        }
    }

    private func run(_ statements: [String]) async {
        guard !statements.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        outcomes = []
        selectedRows = []
        resultSearch = ""
        for statement in statements {
            let outcome = StatementOutcome(statement: statement)
            outcomes.append(outcome)
            selectedOutcomeID = outcome.id
            guard await stream(QueryLimit.apply(rowLimit, to: statement), into: outcome) else { break }
        }
        selectedOutcomeID = outcomes.last(where: \.returnsRows)?.id ?? outcomes.last?.id
        if outcomes.contains(where: { isSchemaChange($0.statement) }) { await workspace.loadTables() }
    }

    /// Returns false when the script must stop (error or cancelled confirmation).
    private func stream(_ sql: String, into outcome: StatementOutcome) async -> Bool {
        do {
            let summary = try await workspace.stream(sql) { chunk in
                Task { @MainActor in outcome.append(chunk) }
            }
            // Chunks hop to the main actor asynchronously; let them land before finishing.
            await Task.yield()
            outcome.finish(summary)
            if outcome.returnsRows {
                Task { outcome.setSource(await workspace.resultSource(for: outcome.columns)) }
            }
            return true
        } catch is CancellationError {
            outcomes.removeAll { $0.id == outcome.id }
            return false
        } catch {
            outcome.fail(error.localizedDescription)
            return false
        }
    }

    /// ⌘S on an editable result: the same safe-mode confirmation and transaction as table tabs.
    func commit(_ outcome: StatementOutcome) async {
        guard !outcome.changes.isEmpty else { return }
        do {
            try await workspace.commit(outcome.pendingStatements)
            outcome.applyCommittedChanges()
            selectedRows = []
        } catch is CancellationError {
            return
        } catch {
            outcome.editError = error.localizedDescription
        }
    }

    private func isSchemaChange(_ statement: String) -> Bool {
        let keyword = statement.drop { $0.isWhitespace }.prefix { $0.isLetter }.lowercased()
        return ["create", "drop", "alter"].contains(keyword)
    }
}
