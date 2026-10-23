import SwiftUI
import TabulaCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var search = ""
    @State private var selection: TableReference?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            schemaHeader
            List(selection: $selection) {
                section("Tabelle", kinds: [.table])
                section("Viste", kinds: [.view, .materializedView])
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 22)
            .overlay {
                if model.phase == .connected, model.tables.isEmpty {
                    Text("Nessuna tabella in \(model.selectedSchema)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .onChange(of: selection) { _, reference in
                guard let reference, let table = model.tables.first(where: { $0.reference == reference }) else { return }
                model.openTable(table)
            }
            .onChange(of: model.selectedTabID) { _, _ in
                if case .table(let table) = model.selectedTab { selection = table.reference }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Cerca un elemento…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onChange(of: model.tableSearchFocusRequest) { isSearchFocused = true }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    @ViewBuilder
    private var schemaHeader: some View {
        if model.schemas.count > 1 {
            Menu {
                Picker("Schema", selection: $model.selectedSchema) {
                    ForEach(model.schemas, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.selectedSchema, systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
    }

    @ViewBuilder
    private func section(_ title: String, kinds: Set<TableKind>) -> some View {
        let items = visibleTables.filter { kinds.contains($0.kind) }
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { table in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: table.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(table.kind == .table ? Color.accentColor : .purple)
                            .frame(width: 14)
                        Text(table.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    }
                    .help(table.name)
                    .tag(table.reference)
                    .contextMenu { contextMenu(for: table) }
                }
            }
        }
    }

    private var visibleTables: [TableInfo] {
        search.isEmpty ? model.tables : model.tables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private func contextMenu(for table: TableInfo) -> some View {
        Button("Apri in una nuova tab") { model.openTable(table, inNewTab: true) }
        Button("Copia nome") { Pasteboard.copy(table.name) }
        Button("Nuova query SELECT") {
            model.newQueryTab(sql: "SELECT * FROM \(table.reference.qualifiedName) LIMIT 100;")
        }
    }

    private func icon(for kind: TableKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .view: "eye"
        case .materializedView: "eye.square"
        }
    }
}

/// Flat, equal-width tabs filling the bar, like TablePlus's TBTabView.
struct TabBar: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                TabButton(tab: tab, isSelected: tab.id == model.selectedTabID) {
                    model.selectedTabID = tab.id
                } onClose: {
                    model.closeTab(tab.id)
                }
                .frame(minWidth: 100, maxWidth: .infinity)
            }
            Button { model.newQueryTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 30, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Nuova query (⌘T)")
        }
        .frame(height: 28)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: isQuery ? "chevron.left.forwardslash.chevron.right" : "tablecells")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(tab.title).font(.system(size: 12, weight: isSelected ? .medium : .regular)).lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if hasPendingChanges { Circle().fill(.orange).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 26)
            HStack {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.leading, 8)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isSelected ? Theme.surface : (isHovering ? Theme.hover : .clear))
        .overlay(alignment: .bottom) { if isSelected { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var isQuery: Bool {
        if case .query = tab { return true }
        return false
    }

    private var hasPendingChanges: Bool {
        if case .table(let model) = tab { return !model.changes.isEmpty }
        return false
    }
}
