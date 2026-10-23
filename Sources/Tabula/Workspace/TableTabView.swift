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
            Divider()
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
        HStack(spacing: 10) {
            Picker("", selection: $table.mode) {
                ForEach(TableTabMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if table.mode == .data {
                Button { table.addRow() } label: { Image(systemName: "plus") }
                    .help("Nuova riga")
                    .disabled(!table.canEdit)
                Button { table.deleteSelectedRows() } label: { Image(systemName: "minus") }
                    .help("Elimina righe selezionate")
                    .disabled(!table.canEdit || table.selectedRows.isEmpty)
                Button { table.showsFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .help("Filtri (⌘F)")
                if !table.canEdit, table.structure != nil {
                    Text("Senza chiave primaria: sola lettura").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !table.changes.isEmpty {
                Button("\(table.changes.count) modifiche") { showsPendingSQL = true }
                    .buttonStyle(.link)
                Button("Annulla") { table.discardChanges() }
                Button("Salva modifiche") { Task { await table.commit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")
            }
            if table.mode == .data {
                Button { Task { await table.goToPage(-1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(!table.hasPreviousPage)
                Text(table.pageDescription).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { Task { await table.goToPage(1) } } label: { Image(systemName: "chevron.right") }
                    .disabled(!table.hasNextPage)
                Button { Task { await table.loadData() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Ricarica")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
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
