import SwiftUI
import TabulaCore

struct TableTabView: View {
    @Bindable var table: TableTabModel

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
                onSort: { column, ascending in
                    guard table.mayDiscardChanges() else { return false }
                    Task { await table.sort(by: table.columns[column].name, ascending: ascending) }
                    return true
                },
                table: table.reference,
                onDeleteRows: table.canEdit ? { table.deleteSelectedRows() } : nil,
                firstRowNumber: table.query.page * table.query.pageSize + 1
            ),
            selection: $table.selectedRows
        )
        .overlay {
            if table.isLoading, table.rowCount == 0 { ProgressView() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Picker(selection: $table.mode) {
                ForEach(TableTabMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {}
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            if table.mode == .data {
                BarDivider()
                BarTextButton(title: "+ Row", isOn: false) { table.addRow() }
                    .disabled(!table.canEdit)
                    .help("New Row")
                BarTextButton(title: "Delete", isOn: false) { table.deleteSelectedRows() }
                    .disabled(!table.canEdit || table.selectedRows.isEmpty)
                    .help("Delete selected rows (⌫)")
                BarTextButton(title: "Filters", isOn: table.showsFilters) { table.showsFilters.toggle() }
                    .help("Filters (⌘F)")
                if !table.canEdit, table.structure != nil {
                    Text("No primary key: read-only").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            Spacer(minLength: 12)
            if !table.changes.isEmpty {
                PendingChangesControls(count: table.changes.count, statements: table.pendingStatements) {
                    table.discardChanges()
                } onSave: {
                    Task { await table.commit() }
                }
            }
            if table.mode == .data {
                Button { Task { await table.goToPage(-1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(!table.hasPreviousPage)
                Text(table.pageDescription)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Button { Task { await table.goToPage(1) } } label: { Image(systemName: "chevron.right") }
                    .disabled(!table.hasNextPage)
                BarDivider()
                Button { Task { await table.refresh() } } label: {
                    if table.isLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Reload")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
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
                Button("Add Filter", systemImage: "plus") {
                    table.filters.append(ColumnFilter(column: nil, op: .contains, value: ""))
                }
                Spacer()
                Button("Clear") { Task { await table.clearFilters() } }
                Button("Apply") { Task { await table.applyFilters() } }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
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
            Picker(selection: $filter.column) {
                Text("Any column").tag(String?.none)
                ForEach(columns, id: \.self) { Text($0).tag(String?.some($0)) }
            } label: {}
            .frame(width: 180)
            Picker(selection: $filter.op) {
                ForEach(FilterOperator.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {}
            .frame(width: 130)
            TextField("Value", text: $filter.value)
                .disabled(!filter.op.needsValue)
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
        .labelsHidden()
        .controlSize(.small)
    }
}

struct StructureView: View {
    let table: TableTabModel

    var body: some View {
        if let structure = table.structure {
            VSplitView {
                Table(structure.columns) {
                    TableColumn("Column") { column in
                        HStack(spacing: 4) {
                            if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption) }
                            Text(column.name)
                        }
                    }
                    TableColumn("Type", value: \.dataType)
                    TableColumn("Nullable") { Text(verbatim: $0.isNullable ? "YES" : "NO") }.width(70)
                    TableColumn("Default") { Text($0.defaultExpression ?? "NULL").foregroundStyle($0.defaultExpression == nil ? .tertiary : .primary) }
                }
                .frame(minHeight: 160)
                Table(structure.indexes) {
                    TableColumn("Index", value: \.name).width(220)
                    TableColumn("Definition") { Text($0.definition).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                }
                .frame(minHeight: 100)
            }
        } else {
            ProgressView()
        }
    }
}
