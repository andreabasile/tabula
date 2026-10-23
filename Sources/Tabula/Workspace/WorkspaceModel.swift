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
    private(set) var connection: ConnectionConfig
    private(set) var phase: ConnectionPhase = .connecting
    private(set) var status = ConnectionStatus()
    private(set) var databases: [String] = []
    /// The database actually in use: libpq falls back to the user name when none is set.
    private(set) var currentDatabase = ""
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
    private(set) var runningQueries = 0
    var presentedSheet: WorkspaceSheet?
    /// Bumped by ⌘P to move focus to the sidebar search field.
    var tableSearchFocusRequest = 0

    private var session: ManagedSession
    private let sessionFactory: SessionFactory
    private let storedPassword: String?
    private let passwordBox = PasswordBox()
    /// Holds this window's share of any tunnel opened by the pre-connect script.
    private let tunnelOwner = UUID()
    private var queryCounter = 0

    init(connection: ConnectionConfig, appModel: AppModel) {
        self.connection = connection
        self.safeMode = connection.safeMode
        self.sessionFactory = appModel.sessionFactory
        self.storedPassword = appModel.savedPassword(for: connection.id)
        self.session = Self.makeSession(connection, factory: appModel.sessionFactory, owner: tunnelOwner, passwordBox: passwordBox, storedPassword: storedPassword)
        if case .postgres(let settings) = connection.kind, settings.passwordStorage == .askEveryTime {
            phase = .needsPassword
        }
    }

    private static func makeSession(
        _ connection: ConnectionConfig,
        factory: SessionFactory,
        owner: UUID,
        passwordBox: PasswordBox,
        storedPassword: String?
    ) -> ManagedSession {
        factory.makeSession(for: connection, owner: owner) { await passwordBox.value ?? storedPassword }
    }

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var isDSQL: Bool {
        if case .dsql = connection.kind { return true }
        return false
    }

    // MARK: Connection

    func start() async {
        guard phase != .needsPassword else { return }
        await observe(session)
        await connect()
    }

    private func observe(_ session: ManagedSession) async {
        await session.onStatusChange { [weak self] status in
            Task { @MainActor in self?.status = status }
        }
    }

    /// Reopens the session on another database of the same server, closing open tabs.
    func switchDatabase(to database: String) async {
        guard database != currentDatabase else { return }
        await session.close()
        connection = connection.switchingDatabase(to: database)
        session = Self.makeSession(connection, factory: sessionFactory, owner: tunnelOwner, passwordBox: passwordBox, storedPassword: storedPassword)
        tabs = []
        selectedTabID = nil
        tables = []
        schemas = []
        status = ConnectionStatus()
        await start()
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
            await loadCurrentDatabase()
            await loadSchemas()
            await loadDatabases()
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
        await sessionFactory.tunnels.release(owner: tunnelOwner)
    }

    var hasPreConnectScript: Bool { !(connection.preConnectScript?.isEmpty ?? true) }

    func disconnect() async {
        await session.close()
        phase = .failed("Disconnessa. Premi Riprova per riconnetterti.")
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
        runningQueries += 1
        defer { runningQueries -= 1 }
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

    private func loadCurrentDatabase() async {
        let result = try? await runInternal("SELECT current_database()")
        currentDatabase = result?.rows.first?.first?.textValue ?? connection.database
    }

    func loadDatabases() async {
        guard !isDSQL, let result = try? await runInternal(Introspection.databases) else { return }
        databases = result.rows.compactMap { $0.first?.textValue }
    }

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
