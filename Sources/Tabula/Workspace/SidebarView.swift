import SwiftUI
import TabulaCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var search = ""
    @State private var selection: TableReference?

    var body: some View {
        VStack(spacing: 0) {
            if model.schemas.count > 1 {
                Picker("Schema", selection: $model.selectedSchema) {
                    ForEach(model.schemas, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .padding([.horizontal, .top], 8)
            }
            List(selection: $selection) {
                Section(model.selectedSchema) {
                    ForEach(visibleTables) { table in
                        Label(table.name, systemImage: icon(for: table.kind))
                            .tag(table.reference)
                            .contextMenu { contextMenu(for: table) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, reference in
                guard let reference, let table = model.tables.first(where: { $0.reference == reference }) else { return }
                model.openTable(table)
            }
            .onChange(of: model.selectedTabID) { _, _ in
                if case .table(let table) = model.selectedTab { selection = table.reference }
            }
            TextField("Cerca tabella…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
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

struct TabBar: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    TabButton(tab: tab, isSelected: tab.id == model.selectedTabID) {
                        model.selectedTabID = tab.id
                    } onClose: {
                        model.closeTab(tab.id)
                    }
                    Divider().frame(height: 18)
                }
                Button { model.newQueryTab() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 10)
                    .help("Nuova query")
            }
        }
        .frame(height: 30)
        .background(.bar)
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isQuery ? "terminal" : "tablecells").font(.caption).foregroundStyle(.secondary)
            Text(tab.title).lineLimit(1)
            if hasPendingChanges { Circle().fill(.orange).frame(width: 6, height: 6) }
            Button(action: onClose) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.borderless)
                .opacity(isHovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 110, maxHeight: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.14) : .clear)
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
