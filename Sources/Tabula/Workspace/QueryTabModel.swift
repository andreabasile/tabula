import Foundation
import Observation
import TabulaCore

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
    /// Header-click ordering of one outcome's rows, applied locally without re-running.
    private(set) var resultSort: ResultSort?

    struct ResultSort: Hashable {
        let outcomeID: UUID
        let column: Int
        let ascending: Bool
    }

    /// Weak: a query still running when its window closes must not outlive (or crash on) the workspace.
    private weak var workspace: WorkspaceModel?

    init(title: String, text: String, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        self.workspace = workspace
    }

    var catalog: SchemaCatalog { workspace?.catalog ?? SchemaCatalog() }
    var hasUnsavedChanges: Bool { outcomes.contains { !$0.changes.isEmpty } }

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
        return String(localized: "row \(line), column \(location - lineStart + 1), position \(location)")
    }

    /// Indexes of the rows matching the result search box, in the header-click order.
    func visibleRows(of outcome: StatementOutcome) -> [Int] {
        // shortcut: filtered and sorted again on every redraw, cache it per outcome revision, search and sort if large results feel slow.
        let query = resultSearch.trimmingCharacters(in: .whitespaces)
        var rows = Array(outcome.rows.indices)
        if !query.isEmpty {
            rows = rows.filter { index in
                outcome.rows[index].contains { $0.textValue?.localizedCaseInsensitiveContains(query) == true }
            }
        }
        guard let sort = resultSort, sort.outcomeID == outcome.id, outcome.columns.indices.contains(sort.column) else { return rows }
        return ResultSorting.sort(rows, typeName: outcome.columns[sort.column].typeName, ascending: sort.ascending) {
            outcome.value(row: $0, column: sort.column)
        }
    }

    func sortResult(of outcome: StatementOutcome, by column: Int, ascending: Bool) {
        resultSort = ResultSort(outcomeID: outcome.id, column: column, ascending: ascending)
        // Row positions change, so the old selection would point at other rows.
        selectedRows = []
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
        outcomes.last?.cancel()
        workspace?.cancelRunningQuery()
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
        // Running again replaces the results, and with them any edits not saved with ⌘S.
        guard !hasUnsavedChanges || UnsavedChanges.confirmDiscard() else { return }
        isRunning = true
        defer { isRunning = false }
        outcomes = []
        selectedRows = []
        resultSearch = ""
        resultSort = nil
        for statement in statements {
            let outcome = StatementOutcome(statement: statement)
            outcomes.append(outcome)
            selectedOutcomeID = outcome.id
            guard await stream(QueryLimit.apply(rowLimit, to: statement), into: outcome) else { break }
        }
        selectedOutcomeID = outcomes.last(where: \.returnsRows)?.id ?? outcomes.last?.id
        if outcomes.contains(where: { isSchemaChange($0.statement) }) { await workspace?.loadTables() }
    }

    /// Returns false when the script must stop (error or cancelled confirmation).
    private func stream(_ sql: String, into outcome: StatementOutcome) async -> Bool {
        guard let workspace else { return false }
        do {
            let summary = try await workspace.stream(sql) { chunk in
                // shortcut: chunks keep their order only because main-actor tasks run first-in, first-out, switch to an AsyncStream if that ever stops holding.
                Task { @MainActor in outcome.append(chunk) }
            }
            // Chunks hop to the main actor asynchronously; let them land before finishing.
            await Task.yield()
            guard !outcome.isCancelled else { return false }
            outcome.finish(summary)
            if outcome.returnsRows {
                Task { outcome.setSource(await workspace.resultSource(for: outcome.columns)) }
            }
            return true
        } catch is CancellationError {
            outcomes.removeAll { $0.id == outcome.id }
            return false
        } catch {
            if !outcome.isCancelled { outcome.fail(error.localizedDescription) }
            return false
        }
    }

    /// ⌘S on an editable result: the same safe-mode confirmation and transaction as table tabs.
    func commit(_ outcome: StatementOutcome) async {
        guard !outcome.changes.isEmpty, let workspace else { return }
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
        ["create", "drop", "alter"].contains(StatementClassifier.firstKeyword(of: statement) ?? "")
    }
}
