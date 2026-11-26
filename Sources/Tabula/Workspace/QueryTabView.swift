import AppKit
import SwiftUI
import TabulaCore

struct QueryTabView: View {
    @Bindable var query: QueryTabModel
    @State private var resultMode: ResultMode = .data
    @State private var showsSearch = false
    /// The outcome whose error banner was closed; the error stays in the messages list.
    @State private var dismissedErrorID: UUID?

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SQLEditor(
                    text: $query.text,
                    selection: $query.selection,
                    onRunCurrent: { Task { await query.runCurrent() } },
                    onRunAll: { Task { await query.runAll() } },
                    catalog: query.catalog
                )
                editorFooter
            }
            .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 280, maxHeight: .infinity)
            VStack(spacing: 0) {
                if showsSearch, resultMode == .data { searchBar }
                results.frame(maxWidth: .infinity, maxHeight: .infinity)
                resultFooter
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editor footer

    private var editorFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft").foregroundStyle(.tertiary)
            Text(query.cursorDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Limit", selection: $query.rowLimit) {
                    ForEach(QueryLimit.choices, id: \.self) { limit in
                        Text(limitTitle(limit)).tag(limit)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(limitTitle(query.rowLimit))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Adds LIMIT to SELECT statements that don’t have one")
            BarDivider()
            Button("Beautify ⌘I") { query.beautify() }
                .keyboardShortcut("i")
            BarDivider()
            if query.isRunning {
                Button("Cancel ⌘.") { query.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .foregroundStyle(.red)
            } else {
                Menu {
                    Button("Run All ⇧⌘↩") { Task { await query.runAll() } }
                } label: {
                    Text("Run Current ⌘↩")
                } primaryAction: {
                    Task { await query.runCurrent() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        switch resultMode {
        case .data: resultGrid
        case .message: messages
        }
    }

    @ViewBuilder
    private var resultGrid: some View {
        if let outcome = query.selectedOutcome {
            if let error = outcome.error {
                if dismissedErrorID != outcome.id {
                    ErrorBanner(message: error) { dismissedErrorID = outcome.id }
                }
                Spacer()
            } else if outcome.returnsRows {
                let visible = query.visibleRows(of: outcome)
                VStack(spacing: 0) {
                    if let error = outcome.editError {
                        ErrorBanner(message: error) { outcome.editError = nil }
                    }
                    DataGrid(
                        source: DataGridSource(
                            columns: outcome.columns,
                            rowCount: visible.count,
                            revision: outcome.revision &+ query.resultSearch.hashValue &+ query.resultSort.hashValue,
                            isEditable: outcome.isEditable,
                            canEditColumn: { outcome.canEdit(column: $0) },
                            value: { outcome.value(row: visible[$0], column: $1) },
                            state: { outcome.state(row: visible[$0], column: $1) },
                            onEdit: { outcome.setValue($2, row: visible[$0], column: $1) },
                            onSort: { query.sortResult(of: outcome, by: $0, ascending: $1); return true },
                            table: outcome.source?.table,
                            onDeleteRows: outcome.isEditable ? { outcome.deleteRows(query.selectedRows.map { visible[$0] }) } : nil
                        ),
                        selection: $query.selectedRows
                    )
                }
            } else if outcome.isRunning {
                ResultPlaceholder(systemImage: "hourglass", text: String(localized: "Running…"))
            } else {
                ResultPlaceholder(systemImage: "checkmark.circle", text: outcome.commandTag)
            }
        } else {
            ResultPlaceholder(systemImage: "play", text: String(localized: "⌘↩ runs the statement under the cursor, ⇧⌘↩ runs the whole script"))
        }
    }

    private var messages: some View {
        List(query.outcomes) { outcome in
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.statement).font(.system(.callout, design: .monospaced)).lineLimit(3)
                if let error = outcome.error {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                } else {
                    Text(summary(of: outcome)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Search results…", text: $query.resultSearch)
                .textFieldStyle(.plain)
            Button { showsSearch = false; query.resultSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Result footer

    private var resultFooter: some View {
        HStack(spacing: 4) {
            Picker(selection: $resultMode) {
                ForEach(ResultMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {}
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if query.outcomes.count > 1 {
                BarDivider()
                Picker(selection: $query.selectedOutcomeID) {
                    ForEach(Array(query.outcomes.enumerated()), id: \.element.id) { index, outcome in
                        Text(verbatim: "\(index + 1). \(outcome.statement.prefix(40))").tag(UUID?.some(outcome.id))
                    }
                } label: {}
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 220)
            }
            if let outcome = query.selectedOutcome {
                BarDivider()
                ElapsedTime(outcome: outcome)
            }
            Spacer()
            if let outcome = query.selectedOutcome, outcome.returnsRows {
                Text(rowCountText(outcome))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let outcome = query.selectedOutcome, !outcome.changes.isEmpty {
                PendingChangesControls(count: outcome.changes.count, statements: outcome.pendingStatements) {
                    outcome.discardChanges()
                } onSave: {
                    Task { await query.commit(outcome) }
                }
            } else if let table = query.selectedOutcome?.source?.table, !query.isRunning {
                Text(table.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Editable result: changes are applied to \(table.qualifiedName)")
                BarDivider()
            }
            Button { showsSearch.toggle() } label: { Image(systemName: "magnifyingglass") }
                .help("Search results")
                .disabled(query.selectedOutcome?.returnsRows != true)
            Menu("Export…") {
                ForEach(RowCopyFormat.allCases, id: \.self) { format in
                    Button(format.title) { export(as: format) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(query.selectedOutcome?.returnsRows != true || query.isRunning)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func limitTitle(_ limit: Int) -> String {
        limit == 0 ? String(localized: "No limit") : String(localized: "Limit \(limit)")
    }

    private func rowCountText(_ outcome: StatementOutcome) -> String {
        let total = outcome.rows.count.formatted()
        guard !query.resultSearch.isEmpty else {
            return outcome.isRunning ? String(localized: "\(total) rows so far…") : String(localized: "\(total) rows")
        }
        let visible = query.visibleRows(of: outcome).count.formatted()
        return outcome.isRunning ? String(localized: "\(visible) of \(total) rows so far…") : String(localized: "\(visible) of \(total) rows")
    }

    private func summary(of outcome: StatementOutcome) -> String {
        let time = outcome.duration.map { String(format: "%.3f s", $0) } ?? String(localized: "in progress")
        return outcome.returnsRows ? String(localized: "\(outcome.rows.count.formatted()) rows · \(time)") : "\(outcome.commandTag) · \(time)"
    }

    private func export(as format: RowCopyFormat) {
        guard let outcome = query.selectedOutcome else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(String(localized: "result")).\(fileExtension(for: format))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = query.visibleRows(of: outcome).map { outcome.rows[$0] }
        let text = RowCopyFormatter.format(rows, columns: outcome.columns.map(\.name), as: format)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func fileExtension(for format: RowCopyFormat) -> String {
        switch format {
        case .csv, .csvWithHeader: "csv"
        case .json: "json"
        case .sqlInsert: "sql"
        case .markdown: "md"
        case .plainText: "txt"
        }
    }
}

/// "6.154 s" in the footer, ticking while the statement runs.
private struct ElapsedTime: View {
    let outcome: StatementOutcome

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: 4) {
                if outcome.isRunning { ProgressView().controlSize(.mini) }
                Text(String(format: "%.3f s", outcome.duration ?? context.date.timeIntervalSince(outcome.startedAt)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(outcome.error == nil ? Color.secondary : Color.red)
            }
        }
    }
}

private enum ResultMode: CaseIterable {
    case data, message

    var title: String {
        switch self {
        case .data: String(localized: "Data")
        case .message: String(localized: "Messages")
        }
    }
}

private struct ResultPlaceholder: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
    }
}
