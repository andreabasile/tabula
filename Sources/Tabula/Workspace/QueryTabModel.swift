import Foundation
import Observation
import TabulaCore

struct StatementOutcome: Identifiable {
    let id = UUID()
    let statement: String
    let result: QueryResult?
    let error: String?
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

    private unowned let workspace: WorkspaceModel

    init(title: String, text: String, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        self.workspace = workspace
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

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

    private func run(_ statements: [String]) async {
        guard !statements.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var collected: [StatementOutcome] = []
        for statement in statements {
            do {
                collected.append(StatementOutcome(statement: statement, result: try await workspace.run(statement), error: nil))
            } catch is CancellationError {
                break
            } catch {
                collected.append(StatementOutcome(statement: statement, result: nil, error: error.localizedDescription))
                break
            }
        }
        guard !collected.isEmpty else { return }
        outcomes = collected
        selectedOutcomeID = collected.last(where: { $0.result?.returnsRows == true })?.id ?? collected.last?.id
        selectedRows = []
        if collected.contains(where: { isSchemaChange($0.statement) }) { await workspace.loadTables() }
    }

    private func isSchemaChange(_ statement: String) -> Bool {
        let keyword = statement.drop { $0.isWhitespace }.prefix { $0.isLetter }.lowercased()
        return ["create", "drop", "alter"].contains(keyword)
    }
}
