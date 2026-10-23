import Foundation
import Observation
import TabulaCore

struct LogEntry: Identifiable {
    enum Outcome { case success(String), failure(String) }

    let id = UUID()
    let date: Date
    let sql: String
    let outcome: Outcome
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let statements: [String]
    let resume: (Bool) -> Void
}

@MainActor
enum WorkspaceTab: @MainActor Identifiable {
    case table(TableTabModel)
    case query(QueryTabModel)

    var id: UUID {
        switch self {
        case .table(let model): model.id
        case .query(let model): model.id
        }
    }

    var title: String {
        switch self {
        case .table(let model): model.reference.name
        case .query(let model): model.title
        }
    }
}

enum ConnectionPhase: Equatable {
    case needsPassword
    case connecting
    case connected
    case failed(String)
}

@MainActor
@Observable
final class WorkspaceModel {
    let connection: ConnectionConfig
    private(set) var phase: ConnectionPhase = .connecting
    private(set) var status = ConnectionStatus()
    private(set) var schemas: [String] = []
    var selectedSchema = "public" { didSet { if oldValue != selectedSchema { Task { await loadTables() } } } }
    private(set) var tables: [TableInfo] = []
    private(set) var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    private(set) var log: [LogEntry] = []
    var safeMode: SafeMode
    var pendingConfirmation: PendingConfirmation?
    var showsConsole = false
    var showsRowDetail = true

    private let session: ManagedSession
    private var askedPassword: String?
    private var queryCounter = 0

    init(connection: ConnectionConfig, appModel: AppModel) {
        self.connection = connection
        self.safeMode = connection.safeMode
        let storedPassword = appModel.savedPassword(for: connection.id)
        let passwordBox = PasswordBox()
        self.session = appModel.sessionFactory.makeSession(for: connection) {
            await passwordBox.value ?? storedPassword
        }
        self.passwordBox = passwordBox
        if case .postgres(let settings) = connection.kind, settings.passwordStorage == .askEveryTime {
            phase = .needsPassword
        }
    }

    private let passwordBox: PasswordBox

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var isDSQL: Bool {
        if case .dsql = connection.kind { return true }
        return false
    }

    // MARK: Connection

    func start() async {
        guard phase != .needsPassword else { return }
        await session.onStatusChange { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
        await connect()
    }

    func providePassword(_ password: String) async {
        await passwordBox.set(password)
        phase = .connecting
        await start()
    }

    func connect() async {
        phase = .connecting
        do {
            try await session.connect()
            phase = .connected
            await loadSchemas()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reconnect() async {
        phase = .connecting
        do {
            try await session.reconnect()
            phase = .connected
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() async {
        await session.close()
    }

    // MARK: Queries

    /// Every query from the UI goes through here: safe mode, console log, errors.
    func run(_ sql: String) async throws -> QueryResult {
        guard await confirmIfNeeded([sql]) else { throw CancellationError() }
        return try await logged(sql) { try await session.execute(sql) }
    }

    /// Runs metadata queries without safe-mode prompts; they are read-only by construction.
    func runInternal(_ sql: String) async throws -> QueryResult {
        try await logged(sql) { try await session.execute(sql) }
    }

    func commit(_ statements: [String]) async throws {
        guard await confirmIfNeeded(statements) else { throw CancellationError() }
        let script = statements.joined(separator: "\n")
        _ = try await logged(script) {
            try await session.executeInTransaction(statements)
            return QueryResult(columns: [], rows: [], commandTag: "COMMIT", duration: 0)
        }
    }

    private func logged(_ sql: String, _ operation: () async throws -> QueryResult) async throws -> QueryResult {
        do {
            let result = try await operation()
            append(LogEntry(date: Date(), sql: sql, outcome: .success(summary(of: result))))
            phase = .connected
            return result
        } catch {
            append(LogEntry(date: Date(), sql: sql, outcome: .failure(error.localizedDescription)))
            throw error
        }
    }

    private func summary(of result: QueryResult) -> String {
        let time = String(format: "%.0f ms", result.duration * 1000)
        return result.returnsRows ? "\(result.rows.count) righe · \(time)" : "\(result.commandTag) · \(time)"
    }

    private func append(_ entry: LogEntry) {
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func confirmIfNeeded(_ statements: [String]) async -> Bool {
        guard safeMode.requiresConfirmation(for: statements) else { return true }
        return await withCheckedContinuation { continuation in
            pendingConfirmation = PendingConfirmation(statements: statements) { [weak self] approved in
                self?.pendingConfirmation = nil
                continuation.resume(returning: approved)
            }
        }
    }

    // MARK: Schema browser

    func loadSchemas() async {
        guard let result = try? await runInternal(Introspection.schemas) else { return }
        schemas = result.rows.compactMap { $0.first?.textValue }
        if !schemas.contains(selectedSchema), let first = schemas.first {
            selectedSchema = first
        } else {
            await loadTables()
        }
        openTableFromLaunchArguments()
    }

    /// `--table <name>` together with `--connect` opens that table on start.
    private func openTableFromLaunchArguments() {
        let arguments = CommandLine.arguments
        guard tabs.isEmpty, let flag = arguments.firstIndex(of: "--table"), arguments.indices.contains(flag + 1),
              let table = tables.first(where: { $0.name == arguments[flag + 1] })
        else { return }
        openTable(table)
    }

    func loadTables() async {
        let schema = selectedSchema
        guard let result = try? await runInternal(Introspection.tables(schema: schema)) else { return }
        tables = Introspection.parseTables(result, schema: schema)
    }

    // MARK: Tabs

    func openTable(_ table: TableInfo, inNewTab: Bool = false) {
        if let existing = tabs.first(where: { if case .table(let model) = $0 { model.reference == table.reference } else { false } }) {
            selectedTabID = existing.id
            return
        }
        let model = TableTabModel(reference: table.reference, workspace: self)
        // Like TablePlus, a single click reuses the current clean table tab.
        if !inNewTab, let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
           case .table(let current) = tabs[index], current.changes.isEmpty {
            tabs[index] = .table(model)
        } else {
            tabs.append(.table(model))
        }
        selectedTabID = model.id
        Task { await model.load() }
    }

    func newQueryTab(sql: String = "") {
        queryCounter += 1
        let model = QueryTabModel(title: "Query \(queryCounter)", text: sql, workspace: self)
        tabs.append(.query(model))
        selectedTabID = model.id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func refreshAll() async {
        await loadSchemas()
        if case .table(let model) = selectedTab { await model.reloadStructureAndData() }
    }
}

/// Holds an "ask every time" password typed after the window opened.
actor PasswordBox {
    private(set) var value: String?
    func set(_ password: String) { value = password }
}
