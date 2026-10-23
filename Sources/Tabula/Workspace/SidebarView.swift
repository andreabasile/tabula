import SwiftUI
import TabulaCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var search = ""
    @State private var selection: TableReference?
    @State private var showsTables = true
    @State private var showsViews = true
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: $selection) {
                section("Tabelle", kinds: [.table], isExpanded: $showsTables)
                section("Viste", kinds: [.view, .materializedView], isExpanded: $showsViews)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 20)
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
            footer
        }
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// Search on top, as in TablePlus's "Search for item…".
    private var searchField: some View {
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
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
        .padding(8)
    }

    /// "+" for a new query and the schema popup at the bottom, as in TablePlus.
    private var footer: some View {
        HStack(spacing: 6) {
            Button { model.newQueryTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Nuova query (⌘T)")
            Picker("", selection: $model.selectedSchema) {
                ForEach(model.schemas, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .disabled(model.schemas.count < 2)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func section(_ title: String, kinds: Set<TableKind>, isExpanded: Binding<Bool>) -> some View {
        let items = visibleTables.filter { kinds.contains($0.kind) }
        if !items.isEmpty {
            Section(isExpanded: isExpanded) {
                ForEach(items) { table in
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: table.kind))
                            .font(.system(size: 11))
                            .foregroundStyle(table.kind == .table ? Color.accentColor : .purple)
                            .frame(width: 14)
                        Text(table.name)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(table.name)
                    .tag(table.reference)
                    .contextMenu { contextMenu(for: table) }
                }
            } header: {
                Text("\(title) (\(items.count))")
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
