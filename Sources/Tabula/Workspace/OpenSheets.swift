import SwiftUI
import TabulaCore

enum WorkspaceSheet: String, Identifiable {
    case connections, databases
    var id: String { rawValue }
}

/// ⌘K inside a workspace, after TablePlus's "Open Connection" window.
struct OpenConnectionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let workspace: WorkspaceModel
    @State private var search = ""
    @State private var selection: UUID?

    var body: some View {
        PickerSheet(
            title: "Apri connessione",
            searchPrompt: "Cerca una connessione…",
            search: $search,
            primaryTitle: "Apri",
            canConfirm: selection != nil,
            onConfirm: open,
            extraButtons: {
                Button("Nuova…") {
                    dismiss()
                    openWindow(id: WindowID.welcome)
                }
            }
        ) {
            List(selection: $selection) {
                ForEach(filtered) { connection in
                    HStack(spacing: 10) {
                        DriverIcon(kind: connection.kind, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(connection.name).fontWeight(.medium)
                                TagBadge(tag: connection.tag)
                            }
                            Text("\(connection.host) : \(connection.database)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if appModel.isOpen(connection.id) {
                            Text("aperta").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(connection.id)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { _ in open() }
        }
        .onAppear { selection = filtered.first?.id }
    }

    private var filtered: [ConnectionConfig] {
        appModel.connections.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)
        }
    }

    private func open() {
        guard let selection, let connection = appModel.connection(selection) else { return }
        dismiss()
        appModel.openWorkspace(for: connection)
    }
}

/// ⌘D, after TablePlus's "Open database" window.
struct OpenDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceModel
    @State private var search = ""
    @State private var selection: String?

    var body: some View {
        PickerSheet(
            title: "Apri database",
            searchPrompt: "Cerca un database…",
            search: $search,
            primaryTitle: "Apri",
            canConfirm: selection != nil,
            onConfirm: open,
            extraButtons: { EmptyView() }
        ) {
            List(filtered, id: \.self, selection: $selection) { name in
                HStack {
                    Image(systemName: "cylinder").foregroundStyle(.secondary)
                    Text(name)
                    Spacer()
                    if name == model.currentDatabase {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in open() }
        }
        .task {
            await model.loadDatabases()
            selection = model.currentDatabase
        }
    }

    private var filtered: [String] {
        model.databases.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }

    private func open() {
        guard let selection else { return }
        dismiss()
        Task { await model.switchDatabase(to: selection) }
    }
}

private struct PickerSheet<Content: View, Extra: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let searchPrompt: String
    @Binding var search: String
    let primaryTitle: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    @ViewBuilder let extraButtons: () -> Extra
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 14)
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            content()
                .frame(height: 300)
            Divider()
            HStack {
                extraButtons()
                Spacer()
                Button("Annulla") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
            .padding(12)
        }
        .frame(width: 480)
    }
}
