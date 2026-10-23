import Foundation
import Observation
import TabulaCore

enum TableTabMode: String, CaseIterable {
    case data = "Dati"
    case structure = "Struttura"
}

enum CellState {
    case normal, edited, inserted, deleted
}

@MainActor
@Observable
final class TableTabModel {
    let id = UUID()
    let reference: TableReference
    var mode: TableTabMode = .data
    private(set) var structure: TableStructure?
    private(set) var result: QueryResult?
    private(set) var totalCount: Int?
    private(set) var query: TableQuery
    private(set) var changes = ChangeSet()
    private(set) var isLoading = false
    var errorMessage: String?
    var selectedRows = IndexSet()
    var filters: [ColumnFilter] = []
    var showsFilters = false
    /// Bumped on every change that the grid must redraw.
    private(set) var revision = 0

    private unowned let workspace: WorkspaceModel

    init(reference: TableReference, workspace: WorkspaceModel) {
        self.reference = reference
        self.query = TableQuery(table: reference)
        self.workspace = workspace
    }

    var columns: [ResultColumn] { result?.columns ?? [] }
    var columnNames: [String] { columns.map(\.name) }
    var primaryKey: [String] { structure?.primaryKey ?? [] }
    var canEdit: Bool { !primaryKey.isEmpty }
    var rowCount: Int { (result?.rows.count ?? 0) + changes.inserts.count }

    // MARK: Loading

    func load() async {
        if structure == nil { await loadStructure() }
        await loadData()
    }

    func reloadStructureAndData() async {
        structure = nil
        await load()
    }

    func loadStructure() async {
        do {
            let columns = Introspection.parseColumns(try await workspace.runInternal(Introspection.columns(reference)))
            let indexes = Introspection.parseIndexes(try await workspace.runInternal(Introspection.indexes(reference)))
            structure = TableStructure(columns: columns, indexes: indexes)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadData() async {
        isLoading = true
        defer { isLoading = false }
        let names = structure?.columns.map(\.name) ?? columnNames
        do {
            result = try await workspace.runInternal(query.selectSQL(columns: names))
            changes = ChangeSet()
            selectedRows = []
            errorMessage = nil
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
        Task { await loadCount(columns: names) }
    }

    private func loadCount(columns: [String]) async {
        let countSQL = query.countSQL(columns: columns)
        guard let result = try? await workspace.runInternal(countSQL) else { return }
        totalCount = result.rows.first?.first?.textValue.flatMap(Int.init)
    }

    // MARK: Paging, sorting, filters

    var pageDescription: String {
        let start = query.page * query.pageSize
        let loaded = result?.rows.count ?? 0
        guard loaded > 0 else { return "0 righe" }
        let total = totalCount.map { " di \($0)" } ?? ""
        return "\(start + 1)–\(start + loaded)\(total)"
    }

    var hasNextPage: Bool {
        guard let totalCount else { return (result?.rows.count ?? 0) == query.pageSize }
        return (query.page + 1) * query.pageSize < totalCount
    }

    var hasPreviousPage: Bool { query.page > 0 }

    func goToPage(_ delta: Int) async {
        query.page = max(0, query.page + delta)
        await loadData()
    }

    func sort(by column: String, ascending: Bool) async {
        query.sort = SortOrder(column: column, ascending: ascending)
        query.page = 0
        await loadData()
    }

    func applyFilters() async {
        query.filters = filters
        query.page = 0
        await loadData()
    }

    func clearFilters() async {
        filters = []
        await applyFilters()
    }

    // MARK: Values and editing

    func value(row: Int, column: Int) -> CellValue {
        let name = columns[column].name
        guard let original = originalRow(row) else {
            return changes.inserts[row - (result?.rows.count ?? 0)][name] ?? .defaultValue
        }
        if let key = rowKey(row), let edited = changes.updates[key]?[name] { return edited }
        return original[column]
    }

    func state(row: Int, column: Int) -> CellState {
        guard originalRow(row) != nil else { return .inserted }
        guard let key = rowKey(row) else { return .normal }
        if changes.deletes.contains(key) { return .deleted }
        return changes.updates[key]?[columns[column].name] != nil ? .edited : .normal
    }

    func setValue(_ value: CellValue, row: Int, column: Int) {
        let name = columns[column].name
        if originalRow(row) == nil {
            changes.updateInsertedValue(value, column: name, at: row - (result?.rows.count ?? 0))
        } else if let key = rowKey(row) {
            guard value != originalRow(row)?[column] else { return }
            changes.setValue(value, column: name, row: key)
        }
        revision += 1
    }

    func addRow() {
        changes.insert(Dictionary(uniqueKeysWithValues: columnNames.map { ($0, CellValue.defaultValue) }))
        selectedRows = [rowCount - 1]
        revision += 1
    }

    func deleteSelectedRows() {
        let loaded = result?.rows.count ?? 0
        for row in selectedRows.sorted(by: >) {
            if row >= loaded {
                changes.removeInsert(at: row - loaded)
            } else if let key = rowKey(row) {
                changes.delete(key)
            }
        }
        revision += 1
    }

    func discardChanges() {
        changes = ChangeSet()
        revision += 1
    }

    var pendingStatements: [String] {
        changes.statements(for: reference, columnOrder: columnNames)
    }

    func commit() async {
        guard !changes.isEmpty else { return }
        do {
            try await workspace.commit(pendingStatements)
            await loadData()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rows(_ indexes: IndexSet) -> [[CellValue]] {
        indexes.filter { $0 < rowCount }.map { row in columns.indices.map { value(row: row, column: $0) } }
    }

    private func originalRow(_ row: Int) -> [CellValue]? {
        guard let rows = result?.rows, rows.indices.contains(row) else { return nil }
        return rows[row]
    }

    private func rowKey(_ row: Int) -> ChangeSet.RowKey? {
        guard canEdit, let original = originalRow(row) else { return nil }
        var values: [String: CellValue] = [:]
        for name in primaryKey {
            guard let index = columnNames.firstIndex(of: name) else { return nil }
            values[name] = original[index]
        }
        return ChangeSet.RowKey(values)
    }
}
