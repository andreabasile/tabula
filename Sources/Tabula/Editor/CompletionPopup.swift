import AppKit
import TabulaCore

/// The suggestion list under the cursor: a borderless child window with a table, driven
/// entirely by the editor's key handling so focus never leaves the text view.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView = NSTableView()
    private(set) var items: [CompletionItem] = []
    var onAccept: ((CompletionItem) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = 456
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = Theme.surfaceNS
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(acceptClicked)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = Theme.surfaceNS.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -3),
        ])
        panel.contentView = container
    }

    func show(_ items: [CompletionItem], below screenPoint: NSPoint, parent: NSWindow) {
        self.items = Array(items.prefix(200))
        guard !self.items.isEmpty else { return hide() }
        tableView.reloadData()
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        let height = CGFloat(min(self.items.count, 9)) * tableView.rowHeight + 6
        panel.setFrame(NSRect(x: screenPoint.x, y: screenPoint.y - height - 2, width: 460, height: height), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(tableView.selectedRow + delta, 0), items.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func acceptSelection() {
        let row = tableView.selectedRow
        guard items.indices.contains(row) else { return }
        onAccept?(items[row])
    }

    @objc private func acceptClicked() {
        acceptSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: CompletionCell.identifier, owner: nil) as? CompletionCell ?? CompletionCell()
        cell.configure(items[row])
        return cell
    }
}

private final class CompletionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CompletionCell")
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        for view in [badge, label, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ item: CompletionItem) {
        let (text, color): (String, NSColor) = switch item.kind {
        case .join: ("JOIN", .systemPurple)
        case .table: ("TAB", .systemBlue)
        case .column: ("COL", .systemTeal)
        case .keyword: ("SQL", .systemPink)
        case .function: ("FN", .systemOrange)
        }
        badge.stringValue = text
        badge.textColor = .white
        badge.layer?.backgroundColor = color.cgColor
        label.stringValue = item.label
        detail.stringValue = item.detail
    }
}
