import AppKit
import SwiftUI
import TabulaCore

/// What the grid needs to draw and edit; closures keep it independent from tab models.
struct DataGridSource {
    var columns: [ResultColumn]
    var rowCount: Int
    var revision: Int
    var isEditable: Bool
    var value: (Int, Int) -> CellValue
    var state: (Int, Int) -> CellState
    var onEdit: (Int, Int, CellValue) -> Void = { _, _, _ in }
    var onSort: ((String, Bool) -> Void)?
    var table: TableReference?
    var onDeleteRows: (() -> Void)?
}

struct DataGrid: NSViewRepresentable {
    let source: DataGridSource
    @Binding var selection: IndexSet

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 24
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.menu = context.coordinator.makeMenu()
        tableView.coordinator = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let columnsChanged = coordinator.parent.source.columns != source.columns
        let needsReload = columnsChanged || coordinator.parent.source.revision != source.revision
            || coordinator.parent.source.rowCount != source.rowCount
        coordinator.parent = self
        if columnsChanged { coordinator.rebuildColumns() }
        if needsReload { coordinator.tableView?.reloadData() }
        if coordinator.tableView?.selectedRowIndexes != selection {
            coordinator.tableView?.selectRowIndexes(selection, byExtendingSelection: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DataGrid
        weak var tableView: NSTableView?

        init(_ parent: DataGrid) {
            self.parent = parent
        }

        func rebuildColumns() {
            guard let tableView else { return }
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            for (index, column) in parent.source.columns.enumerated() {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                tableColumn.title = column.name
                tableColumn.headerToolTip = column.typeName
                tableColumn.width = Self.initialWidth(for: column)
                tableColumn.minWidth = 40
                if parent.source.onSort != nil {
                    tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.name, ascending: true)
                }
                tableView.addTableColumn(tableColumn)
            }
            tableView.reloadData()
        }

        private static func initialWidth(for column: ResultColumn) -> CGFloat {
            let base = CGFloat(column.name.count) * 7.5 + 28
            let typical: CGFloat = switch column.typeName {
            case "bool": 60
            case "int2", "int4", "int8", "oid": 80
            case "uuid": 290
            case "timestamptz", "timestamp": 220
            case "date": 100
            default: 160
            }
            return min(max(base, typical), 420)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.source.rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: GridCell.identifier, owner: nil) as? GridCell ?? GridCell()
            let value = parent.source.value(row, column)
            cell.configure(value: value, state: parent.source.state(row, column), editable: parent.source.isEditable)
            cell.textField?.delegate = self
            cell.textField?.tag = column
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            let rows = tableView.selectedRowIndexes
            DispatchQueue.main.async { [self] in
                if parent.selection != rows { parent.selection = rows }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            parent.source.onSort?(key, descriptor.ascending)
        }

        // MARK: Editing

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let tableView else { return }
            let row = tableView.row(for: field)
            guard row >= 0 else { return }
            let column = field.tag
            let typed = field.stringValue
            let current = parent.source.value(row, column)
            // NULL/DEFAULT/EMPTY show as placeholders, so an untouched cell reads back as "".
            guard typed != GridCell.editableString(current) else { return }
            parent.source.onEdit(row, column, .text(typed))
        }

        func setSelectedCells(to value: CellValue) {
            guard let tableView else { return }
            let column = tableView.clickedColumn >= 0 ? tableView.clickedColumn : tableView.selectedColumn
            guard column >= 0, let index = Int(tableView.tableColumns[column].identifier.rawValue) else { return }
            for row in tableView.selectedRowIndexes { parent.source.onEdit(row, index, value) }
        }

        // MARK: Context menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(item("Copia", #selector(copySelection)))
            menu.addItem(item("Copia valore cella", #selector(copyCellValue)))
            menu.addItem(item("Copia valori della colonna", #selector(copyColumnValues)))
            let copyAs = NSMenuItem(title: "Copia righe come", action: nil, keyEquivalent: "")
            let formats = NSMenu()
            for (index, format) in RowCopyFormat.allCases.enumerated() {
                let entry = item(format.rawValue, #selector(copyAs(_:)))
                entry.tag = index
                formats.addItem(entry)
            }
            copyAs.submenu = formats
            menu.addItem(copyAs)
            menu.addItem(.separator())
            menu.addItem(item("Imposta NULL", #selector(setNull)))
            menu.addItem(item("Imposta DEFAULT", #selector(setDefault)))
            menu.addItem(item("Imposta stringa vuota", #selector(setEmpty)))
            menu.addItem(.separator())
            menu.addItem(item("Elimina righe", #selector(deleteRows)))
            return menu
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        private var targetRows: IndexSet {
            guard let tableView else { return [] }
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) { return [clicked] }
            return tableView.selectedRowIndexes
        }

        private func rows(_ indexes: IndexSet) -> [[CellValue]] {
            indexes.map { row in parent.source.columns.indices.map { parent.source.value(row, $0) } }
        }

        @objc func copySelection() {
            copyRows(as: .plainText)
        }

        @objc func copyAs(_ sender: NSMenuItem) {
            copyRows(as: RowCopyFormat.allCases[sender.tag])
        }

        private func copyRows(as format: RowCopyFormat) {
            let text = RowCopyFormatter.format(rows(targetRows), columns: parent.source.columns.map(\.name), as: format, table: parent.source.table)
            Pasteboard.copy(text)
        }

        @objc func copyCellValue() {
            guard let tableView, let row = targetRows.first else { return }
            let column = max(tableView.clickedColumn, 0)
            guard let index = Int(tableView.tableColumns[column].identifier.rawValue) else { return }
            Pasteboard.copy(parent.source.value(row, index).displayText)
        }

        @objc func copyColumnValues() {
            guard let tableView, tableView.clickedColumn >= 0,
                  let index = Int(tableView.tableColumns[tableView.clickedColumn].identifier.rawValue) else { return }
            let values = (0..<parent.source.rowCount).map { parent.source.value($0, index).displayText }
            Pasteboard.copy(values.joined(separator: "\n"))
        }

        @objc func setNull() { setSelectedCells(to: .null) }
        @objc func setDefault() { setSelectedCells(to: .defaultValue) }
        @objc func setEmpty() { setSelectedCells(to: .text("")) }

        @objc func deleteRows() {
            parent.source.onDeleteRows?()
        }

        func validate(_ item: NSMenuItem) -> Bool {
            let editingActions: [Selector] = [#selector(setNull), #selector(setDefault), #selector(setEmpty)]
            if let action = item.action, editingActions.contains(action) { return parent.source.isEditable }
            if item.action == #selector(deleteRows) { return parent.source.onDeleteRows != nil }
            return parent.source.rowCount > 0
        }
    }
}

extension DataGrid.Coordinator: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validate(menuItem) }
}

/// Adds ⌘C and ⌫ on the grid itself, as in TablePlus.
final class GridTableView: NSTableView {
    weak var coordinator: DataGrid.Coordinator?

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    override func keyDown(with event: NSEvent) {
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if isDelete, !selectedRowIndexes.isEmpty, coordinator?.parent.source.onDeleteRows != nil {
            coordinator?.deleteRows()
            return
        }
        super.keyDown(with: event)
    }
}

final class GridCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("GridCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Multi-line values are shown on one line, as TablePlus does.
    static func editableString(_ value: CellValue) -> String {
        (value.textValue ?? "").replacingOccurrences(of: "\n", with: "⏎")
    }

    private static func placeholder(for value: CellValue) -> String? {
        switch value {
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        case .text(let text): text.isEmpty ? "EMPTY" : nil
        }
    }

    func configure(value: CellValue, state: CellState, editable: Bool) {
        guard let field = textField else { return }
        field.stringValue = Self.editableString(value)
        field.placeholderAttributedString = Self.placeholder(for: value).map {
            NSAttributedString(string: $0, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])
        }
        field.isEditable = editable && state != .deleted
        field.textColor = .labelColor
        layer?.backgroundColor = switch state {
        case .normal: nil
        case .edited: NSColor.systemYellow.withAlphaComponent(0.28).cgColor
        case .inserted: NSColor.systemGreen.withAlphaComponent(0.22).cgColor
        case .deleted: NSColor.systemRed.withAlphaComponent(0.25).cgColor
        }
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
