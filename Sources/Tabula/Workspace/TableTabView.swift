import SwiftUI
import TabulaCore

struct TableTabView: View {
    @Bindable var table: TableTabModel
    @State private var showsPendingSQL = false

    var body: some View {
        VStack(spacing: 0) {
            if table.showsFilters, table.mode == .data { FilterBar(table: table) }
            if let error = table.errorMessage {
                ErrorBanner(message: error) { table.errorMessage = nil }
            }
            switch table.mode {
            case .data: grid
            case .structure: StructureView(table: table)
            }
            bottomBar
        }
        .popover(isPresented: $showsPendingSQL, arrowEdge: .bottom) {
            ScrollView {
                Text(table.pendingStatements.joined(separator: "\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
            .frame(width: 520, height: 220)
        }
    }

    private var grid: some View {
        DataGrid(
            source: DataGridSource(
                columns: table.columns,
                rowCount: table.rowCount,
                revision: table.revision,
                isEditable: table.canEdit,
                value: { table.value(row: $0, column: $1) },
                state: { table.state(row: $0, column: $1) },
                onEdit: { table.setValue($2, row: $0, column: $1) },
                onSort: { column, ascending in Task { await table.sort(by: column, ascending: ascending) } },
                table: table.reference,
                onDeleteRows: table.canEdit ? { table.deleteSelectedRows() } : nil
            ),
            selection: $table.selectedRows
        )
        .overlay {
            if table.isLoading, table.rowCount == 0 { ProgressView() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(TableTabMode.allCases, id: \.self) { mode in
                BarTextButton(title: mode.rawValue, isOn: table.mode == mode) { table.mode = mode }
            }
            if table.mode == .data {
                BarDivider()
                BarTextButton(title: "+ Riga", isOn: false) { table.addRow() }
                    .disabled(!table.canEdit)
                    .help("Nuova riga")
                BarTextButton(title: "Elimina", isOn: false) { table.deleteSelectedRows() }
                    .disabled(!table.canEdit || table.selectedRows.isEmpty)
                    .help("Elimina righe selezionate (⌫)")
                BarTextButton(title: "Filtri", isOn: table.showsFilters) { table.showsFilters.toggle() }
                    .help("Filtri (⌘F)")
                if !table.canEdit, table.structure != nil {
                    Text("Senza chiave primaria: sola lettura").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            Spacer(minLength: 12)
            if !table.changes.isEmpty {
                Button("\(table.changes.count) modifiche") { showsPendingSQL = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                Button("Annulla") { table.discardChanges() }
                    .controlSize(.small)
                Button("Salva ⌘S") { Task { await table.commit() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s")
                BarDivider()
            }
            if table.mode == .data {
                Button { Task { await table.goToPage(-1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(!table.hasPreviousPage)
                Text("\(table.pageDescription) righe")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Button { Task { await table.goToPage(1) } } label: { Image(systemName: "chevron.right") }
                    .disabled(!table.hasNextPage)
                BarDivider()
                Button { Task { await table.loadData() } } label: {
                    if table.isLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Ricarica")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

/// The small text toggles in TablePlus's bottom bar ("Data", "Structure", "+ Row").
struct BarTextButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isEnabled ? (isOn ? .primary : .secondary) : .tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isOn ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 14).padding(.horizontal, 4)
    }
}

private struct FilterBar: View {
    @Bindable var table: TableTabModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(table.filters.indices, id: \.self) { index in
                FilterRow(filter: $table.filters[index], columns: table.columnNames) {
                    table.filters.remove(at: index)
                }
            }
            HStack {
                Button("Aggiungi filtro", systemImage: "plus") {
                    table.filters.append(ColumnFilter(column: nil, op: .contains, value: ""))
                }
                Spacer()
                Button("Pulisci") { Task { await table.clearFilters() } }
                Button("Applica") { Task { await table.applyFilters() } }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.background.secondary)
        .onAppear {
            if table.filters.isEmpty { table.filters = [ColumnFilter(column: nil, op: .contains, value: "")] }
        }
    }
}

private struct FilterRow: View {
    @Binding var filter: ColumnFilter
    let columns: [String]
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Picker("", selection: $filter.column) {
                Text("Qualsiasi colonna").tag(String?.none)
                ForEach(columns, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(width: 180)
            Picker("", selection: $filter.op) {
                ForEach(FilterOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 130)
            TextField("Valore", text: $filter.value)
                .disabled(!filter.op.needsValue)
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
        .labelsHidden()
        .controlSize(.small)
    }
}

struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(.red.opacity(0.1))
    }
}

struct StructureView: View {
    let table: TableTabModel

    var body: some View {
        if let structure = table.structure {
            VSplitView {
                Table(structure.columns) {
                    TableColumn("Colonna") { column in
                        HStack(spacing: 4) {
                            if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption) }
                            Text(column.name)
                        }
                    }
                    TableColumn("Tipo", value: \.dataType)
                    TableColumn("Nullable") { Text($0.isNullable ? "YES" : "NO") }.width(70)
                    TableColumn("Default") { Text($0.defaultExpression ?? "NULL").foregroundStyle($0.defaultExpression == nil ? .tertiary : .primary) }
                }
                .frame(minHeight: 160)
                Table(structure.indexes) {
                    TableColumn("Indice", value: \.name).width(220)
                    TableColumn("Definizione") { Text($0.definition).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
                .frame(minHeight: 100)
            }
        } else {
            ProgressView()
        }
    }
}
