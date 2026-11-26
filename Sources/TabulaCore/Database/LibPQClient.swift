import CLibPQ
import Foundation

public struct LibPQOpener: ConnectionOpening {
    public init() {}

    public func open(_ credentials: ConnectionCredentials) async throws -> DatabaseClient {
        try await LibPQClient.connect(credentials)
    }
}

/// libpq calls are blocking and a PGconn is not thread-safe, so every call runs on
/// the connection's own serial queue. Cancel is the exception: libpq allows it from
/// any thread.
public final class LibPQClient: DatabaseClient, @unchecked Sendable {
    private let connection: OpaquePointer
    private let queue: DispatchQueue
    private let cancelHandle: OpaquePointer?
    private var isClosed = false

    private init(connection: OpaquePointer, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.cancelHandle = PQgetCancel(connection)
    }

    static func connect(_ credentials: ConnectionCredentials) async throws -> LibPQClient {
        let queue = DispatchQueue(label: "tabula.libpq.\(UUID().uuidString)")
        return try await perform(on: queue) {
            let parameters = LibPQParameters.make(for: credentials)
            let connection = parameters.withCStrings { keywords, values in
                PQconnectdbParams(keywords, values, 0)
            }
            guard let connection else { throw DatabaseError.connectionLost(String(localized: "libpq failed to allocate the connection")) }
            guard PQstatus(connection) == CONNECTION_OK else {
                let message = String(cString: PQerrorMessage(connection)).trimmingCharacters(in: .whitespacesAndNewlines)
                PQfinish(connection)
                throw LibPQErrors.connectError(message)
            }
            PQsetNoticeProcessor(connection, { _, _ in }, nil)
            return LibPQClient(connection: connection, queue: queue)
        }
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        try await Self.perform(on: queue) { [self] in try runQuery(sql) }
    }

    public func executeInTransaction(_ statements: [String]) async throws {
        try await Self.perform(on: queue) { [self] in
            try checkCanCommitEdits()
            _ = try runQuery("BEGIN")
            do {
                for statement in statements {
                    // The row changed or vanished since it was read, or a row-level security policy hides it.
                    if LibPQErrors.matchedNoRow(try runQuery(statement).commandTag) {
                        throw DatabaseError.other(String(localized: "A row to save no longer matches: it was changed or deleted in the meantime, or a security policy hides it. Nothing was saved."))
                    }
                }
                _ = try runQuery("COMMIT")
            } catch {
                _ = try? runQuery("ROLLBACK")
                throw error
            }
        }
    }

    public func stream(_ sql: String, chunkSize: Int, onChunk: @escaping @Sendable (ResultChunk) -> Void) async throws -> StreamSummary {
        try await Self.perform(on: queue) { [self] in try runStreaming(sql, chunkSize: chunkSize, onChunk: onChunk) }
    }

    public func isInTransaction() async -> Bool {
        (try? await Self.perform(on: queue) { [self] in
            guard !isClosed else { return false }
            let status = PQtransactionStatus(connection)
            return status == PQTRANS_INTRANS || status == PQTRANS_INERROR
        }) ?? false
    }

    public func serverInfo() async -> ServerInfo {
        (try? await Self.perform(on: queue) { [self] in
            let version = PQparameterStatus(connection, "server_version").map { String(cString: $0) }
            let tls = PQsslInUse(connection) == 1 ? PQsslAttribute(connection, "protocol").map { String(cString: $0) } : nil
            return ServerInfo(version: version, tlsProtocol: tls)
        }) ?? ServerInfo()
    }

    public func cancel() {
        guard let cancelHandle else { return }
        var buffer = [CChar](repeating: 0, count: 256)
        _ = PQcancel(cancelHandle, &buffer, Int32(buffer.count))
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                closeNow()
                continuation.resume()
            }
        }
    }

    deinit {
        if !isClosed {
            if let cancelHandle { PQfreeCancel(cancelHandle) }
            PQfinish(connection)
        }
    }

    private func closeNow() {
        guard !isClosed else { return }
        isClosed = true
        if let cancelHandle { PQfreeCancel(cancelHandle) }
        PQfinish(connection)
    }

    /// Edits are plain SQL sent on the session the user also types into.
    private func checkCanCommitEdits() throws {
        // Our BEGIN would only warn inside the user's own transaction, and our COMMIT would end it.
        guard PQtransactionStatus(connection) == PQTRANS_IDLE else {
            throw DatabaseError.other(String(localized: "A transaction is open in this session: commit or roll it back before saving edits."))
        }
        // Values are quoted by doubling quotes only; with backslash escapes they could be corrupted.
        if PQparameterStatus(connection, "standard_conforming_strings").map({ String(cString: $0) }) == "off" {
            throw DatabaseError.other(String(localized: "Editing is disabled: this server treats backslashes in strings as escapes (standard_conforming_strings is off)."))
        }
    }

    private func runQuery(_ sql: String) throws -> QueryResult {
        guard !isClosed else { throw DatabaseError.connectionLost(String(localized: "connection closed")) }
        let started = Date()
        guard PQsendQuery(connection, sql) == 1 else { throw connectionLevelError() }
        var last: QueryResult?
        var failure: DatabaseError?
        while let result = PQgetResult(connection) {
            defer { PQclear(result) }
            switch PQresultStatus(result) {
            case PGRES_FATAL_ERROR:
                failure = failure ?? serverError(result)
            case PGRES_TUPLES_OK, PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                last = LibPQResultReader.read(result, duration: Date().timeIntervalSince(started))
            default:
                continue
            }
        }
        if let failure { throw failure }
        if PQstatus(connection) != CONNECTION_OK { throw connectionLevelError() }
        return last ?? QueryResult(columns: [], rows: [], commandTag: "", duration: Date().timeIntervalSince(started))
    }

    private func runStreaming(_ sql: String, chunkSize: Int, onChunk: (ResultChunk) -> Void) throws -> StreamSummary {
        guard !isClosed else { throw DatabaseError.connectionLost(String(localized: "connection closed")) }
        let started = Date()
        guard PQsendQuery(connection, sql) == 1 else { throw connectionLevelError() }
        PQsetChunkedRowsMode(connection, Int32(max(chunkSize, 1)))
        var columns: [ResultColumn] = []
        var rowCount = 0
        var commandTag = ""
        var failure: DatabaseError?
        while let result = PQgetResult(connection) {
            defer { PQclear(result) }
            switch PQresultStatus(result) {
            case PGRES_TUPLES_CHUNK:
                let chunk = LibPQResultReader.read(result, duration: 0)
                columns = chunk.columns
                rowCount += chunk.rows.count
                onChunk(ResultChunk(columns: chunk.columns, rows: chunk.rows))
            case PGRES_TUPLES_OK, PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                // In chunked mode the final TUPLES_OK carries no rows, only the shape and the tag.
                let final = LibPQResultReader.read(result, duration: 0)
                if columns.isEmpty { columns = final.columns }
                if !final.rows.isEmpty {
                    rowCount += final.rows.count
                    onChunk(ResultChunk(columns: final.columns, rows: final.rows))
                }
                commandTag = final.commandTag
            case PGRES_FATAL_ERROR:
                failure = failure ?? serverError(result)
            default:
                continue
            }
        }
        if let failure { throw failure }
        if PQstatus(connection) != CONNECTION_OK { throw connectionLevelError() }
        return StreamSummary(columns: columns, rowCount: rowCount, commandTag: commandTag, duration: Date().timeIntervalSince(started))
    }

    private func serverError(_ result: OpaquePointer) -> DatabaseError {
        if PQstatus(connection) != CONNECTION_OK { return connectionLevelError() }
        let field = { (code: Character) -> String? in
            guard let value = PQresultErrorField(result, Int32(code.asciiValue!)) else { return nil }
            return String(cString: value)
        }
        return .server(
            message: field("M") ?? String(cString: PQresultErrorMessage(result)),
            detail: field("D"),
            hint: field("H"),
            sqlState: field("C")
        )
    }

    private func connectionLevelError() -> DatabaseError {
        let message = String(cString: PQerrorMessage(connection)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .connectionLost(message.isEmpty ? String(localized: "the server closed the connection") : message)
    }

    private static func perform<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

enum LibPQErrors {
    static func connectError(_ message: String) -> DatabaseError {
        let lowered = message.lowercased()
        let isAuthentication = ["password authentication failed", "access denied", "authentication failed"]
            .contains { lowered.contains($0) }
        return isAuthentication ? .authenticationFailed(message) : .connectionLost(message)
    }

    /// The command tag of an UPDATE or DELETE that changed nothing.
    static func matchedNoRow(_ commandTag: String) -> Bool {
        commandTag == "UPDATE 0" || commandTag == "DELETE 0"
    }
}

struct LibPQParameters {
    let pairs: [(String, String)]

    static func make(for credentials: ConnectionCredentials) -> LibPQParameters {
        var pairs: [(String, String)] = [
            ("host", credentials.host),
            ("port", String(credentials.port)),
            ("user", credentials.user),
            ("dbname", credentials.database),
            ("connect_timeout", "10"),
            ("application_name", "Tabula"),
        ]
        if let password = credentials.password { pairs.append(("password", password)) }
        pairs += sslPairs(for: credentials)
        return LibPQParameters(pairs: pairs)
    }

    private static func sslPairs(for credentials: ConnectionCredentials) -> [(String, String)] {
        // DSQL presents a publicly trusted certificate, so it can be fully verified. Not "system": the
        // bundled OpenSSL's default store points into Homebrew; macOS keeps its CA bundle at /etc/ssl/cert.pem.
        if credentials.token != nil { return [("sslmode", "verify-full"), ("sslrootcert", "/etc/ssl/cert.pem")] }
        return [("sslmode", credentials.sslMode.libpqName)]
    }

    func withCStrings<T>(_ body: (UnsafePointer<UnsafePointer<CChar>?>, UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let keywords = pairs.map { strdup($0.0) } + [nil]
        let values = pairs.map { strdup($0.1) } + [nil]
        defer {
            keywords.forEach { free($0) }
            values.forEach { free($0) }
        }
        let keywordPointers = keywords.map { UnsafePointer($0) }
        let valuePointers = values.map { UnsafePointer($0) }
        return keywordPointers.withUnsafeBufferPointer { keywordBuffer in
            valuePointers.withUnsafeBufferPointer { valueBuffer in
                body(keywordBuffer.baseAddress!, valueBuffer.baseAddress!)
            }
        }
    }
}

enum LibPQResultReader {
    static func read(_ result: OpaquePointer, duration: TimeInterval) -> QueryResult {
        let fieldCount = PQnfields(result)
        let rowCount = PQntuples(result)
        let columns = (0..<fieldCount).map { field in
            ResultColumn(
                name: String(cString: PQfname(result, field)),
                typeName: PostgresTypeNames.name(for: PQftype(result, field)),
                sourceTable: PQftable(result, field),
                sourceColumn: Int(PQftablecol(result, field))
            )
        }
        let rows = (0..<rowCount).map { row in
            (0..<fieldCount).map { field -> CellValue in
                PQgetisnull(result, row, field) == 1 ? .null : .text(String(cString: PQgetvalue(result, row, field)))
            }
        }
        return QueryResult(columns: columns, rows: rows, commandTag: String(cString: PQcmdStatus(result)), duration: duration)
    }
}
