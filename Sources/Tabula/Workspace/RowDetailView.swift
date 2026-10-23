import SwiftUI
import TabulaCore

/// TablePlus's right sidebar: the selected row as a field list, editable.
struct RowDetailView: View {
    let table: TableTabModel
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Cerca campo…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if let row = selectedRow {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleColumns, id: \.offset) { index, column in
                            FieldEditor(
                                column: column,
                                value: table.value(row: row, column: index),
                                isEditable: table.canEdit && table.state(row: row, column: index) != .deleted
                            ) { table.setValue($0, row: row, column: index) }
                        }
                    }
                    .padding(10)
                }
                .id("\(table.id)-\(row)-\(table.revision)")
            } else {
                Text(table.selectedRows.count > 1 ? "\(table.selectedRows.count) righe selezionate" : "Nessuna riga selezionata")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private var selectedRow: Int? {
        guard table.selectedRows.count == 1, let row = table.selectedRows.first, row < table.rowCount else { return nil }
        return row
    }

    private var visibleColumns: [(offset: Int, element: ResultColumn)] {
        Array(table.columns.enumerated()).filter { search.isEmpty || $0.element.name.localizedCaseInsensitiveContains(search) }
    }
}

private struct FieldEditor: View {
    let column: ResultColumn
    let value: CellValue
    let isEditable: Bool
    let onCommit: (CellValue) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(column.name).font(.caption.weight(.semibold))
                Text(column.typeName).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Menu {
                    Button("NULL") { onCommit(.null) }
                    Button("DEFAULT") { onCommit(.defaultValue) }
                    Button("Stringa vuota") { onCommit(.text("")) }
                } label: {
                    Text(value.textValue == nil ? value.displayText : "").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!isEditable)
            }
            TextField("", text: $text, prompt: Text(value.displayText), axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...8)
                .disabled(!isEditable)
                .onSubmit(commit)
                .onAppear { text = value.textValue ?? "" }
        }
    }

    private func commit() {
        guard text != (value.textValue ?? "") || value.textValue == nil && !text.isEmpty else { return }
        onCommit(.text(text))
    }
}
