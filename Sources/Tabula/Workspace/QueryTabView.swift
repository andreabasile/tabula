import SwiftUI
import TabulaCore

struct QueryTabView: View {
    @Bindable var query: QueryTabModel
    @State private var resultMode: ResultMode = .result

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                SQLEditor(
                    text: $query.text,
                    selection: $query.selection,
                    onRunCurrent: { Task { await query.runCurrent() } },
                    onRunAll: { Task { await query.runAll() } }
                )
                editorBar
            }
            .frame(minHeight: 120, idealHeight: 260)
            results.frame(minHeight: 120)
        }
    }

    private var editorBar: some View {
        HStack {
            Button("Esegui corrente", systemImage: "play.fill") { Task { await query.runCurrent() } }
                .help("⌘↩")
            Button("Esegui tutto", systemImage: "forward.fill") { Task { await query.runAll() } }
                .help("⇧⌘↩")
            if query.isRunning { ProgressView().controlSize(.small) }
            Spacer()
            if query.outcomes.count > 1 {
                Picker("", selection: $query.selectedOutcomeID) {
                    ForEach(Array(query.outcomes.enumerated()), id: \.element.id) { index, outcome in
                        Text("\(index + 1). \(outcome.statement.prefix(40))").tag(UUID?.some(outcome.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            ForEach(ResultMode.allCases, id: \.self) { mode in
                BarTextButton(title: mode.rawValue, isOn: resultMode == mode) { resultMode = mode }
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var results: some View {
        switch resultMode {
        case .result: resultGrid
        case .message: messages
        }
    }

    @ViewBuilder
    private var resultGrid: some View {
        if let outcome = query.selectedOutcome {
            if let error = outcome.error {
                ErrorBanner(message: error) {}
                Spacer()
            } else if let result = outcome.result, result.returnsRows {
                DataGrid(
                    source: DataGridSource(
                        columns: result.columns,
                        rowCount: result.rows.count,
                        revision: outcome.id.hashValue,
                        isEditable: false,
                        value: { result.rows[$0][$1] },
                        state: { _, _ in .normal }
                    ),
                    selection: $query.selectedRows
                )
            } else if let result = outcome.result {
                ContentUnavailableView(result.commandTag, systemImage: "checkmark.circle", description: Text(String(format: "%.0f ms", result.duration * 1000)))
            }
        } else {
            ContentUnavailableView("Nessun risultato", systemImage: "terminal", description: Text("Scrivi una query ed eseguila con ⌘↩"))
        }
    }

    private var messages: some View {
        List(query.outcomes) { outcome in
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.statement).font(.system(.callout, design: .monospaced)).lineLimit(3)
                if let error = outcome.error {
                    Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                } else if let result = outcome.result {
                    Text("\(result.returnsRows ? "\(result.rows.count) righe" : result.commandTag) · \(String(format: "%.0f ms", result.duration * 1000))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum ResultMode: String, CaseIterable {
    case result = "Risultato"
    case message = "Messaggi"
}
