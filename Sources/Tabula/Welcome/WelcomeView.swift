import SwiftUI
import TabulaCore

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editing: ConnectionDraft?
    @State private var importingURL = false
    @State private var pendingDeletion: ConnectionConfig?
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
            Divider()
            connectionList
        }
        .frame(width: 760, height: 460)
        .onAppear(perform: openConnectionFromLaunchArguments)
        .sheet(item: $editing) { draft in
            ConnectionFormView(draft: draft) { saved, shouldConnect in
                editing = nil
                if shouldConnect, let saved { open(saved) }
            }
            .environment(model)
        }
        .sheet(isPresented: $importingURL) {
            ImportURLView { parsed in
                importingURL = false
                if let parsed { editing = ConnectionDraft(imported: parsed) }
            }
        }
        .confirmationDialog(
            "Eliminare la connessione \"\(pendingDeletion?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { connection in
            Button("Elimina", role: .destructive) { perform { try model.delete(connection.id) } }
        }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var leftPanel: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tablecells.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Tabula").font(.title.bold())
            Text("PostgreSQL e Aurora DSQL").font(.callout).foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 8) {
                Button("Crea una nuova connessione…") { editing = ConnectionDraft() }
                    .keyboardShortcut("n")
                Button("Importa da URL…") { importingURL = true }
            }
            .buttonStyle(.link)
            .padding(.bottom, 24)
        }
        .frame(width: 240)
        .background(.background.secondary)
    }

    private var connectionList: some View {
        VStack(spacing: 0) {
            TextField("Cerca una connessione…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(selection: $selection) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name.isEmpty ? "Connessioni" : group.name) {
                        ForEach(group.connections) { connection in
                            ConnectionRow(connection: connection)
                                .tag(connection.id)
                                .contextMenu { contextMenu(for: connection) }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                ids.first.flatMap(model.connection).map(open)
            }
            .overlay {
                if model.connections.isEmpty {
                    ContentUnavailableView("Nessuna connessione", systemImage: "externaldrive", description: Text("Crea la prima con ⌘N"))
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for connection: ConnectionConfig) -> some View {
        Button("Apri") { open(connection) }
        Button("Modifica…") { editing = ConnectionDraft(connection: connection, password: model.savedPassword(for: connection.id)) }
        Button("Duplica") { perform { try model.duplicate(connection) } }
        Button("Copia come URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ConnectionURL.format(connection), forType: .string)
        }
        Divider()
        Button("Elimina", role: .destructive) { pendingDeletion = connection }
    }

    private var groups: [(name: String, connections: [ConnectionConfig])] {
        let query = search.lowercased()
        let visible = model.connections.filter {
            query.isEmpty || $0.name.lowercased().contains(query) || $0.host.lowercased().contains(query)
        }
        return Dictionary(grouping: visible, by: \.group)
            .map { (name: $0.key, connections: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private func open(_ connection: ConnectionConfig) {
        openWindow(id: WindowID.workspace, value: connection.id)
    }

    /// `Tabula --connect "<name>"` opens a saved connection straight away.
    private func openConnectionFromLaunchArguments() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--connect"), arguments.indices.contains(flag + 1) else { return }
        let name = arguments[flag + 1]
        model.connections.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(open)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

private struct ConnectionRow: View {
    let connection: ConnectionConfig

    var body: some View {
        HStack(spacing: 10) {
            DriverIcon(kind: connection.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name).font(.body.weight(.medium))
                    TagBadge(tag: connection.tag)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        switch connection.kind {
        case .postgres(let settings): "\(settings.host) : \(settings.database)"
        case .dsql(let settings):
            "\(settings.endpoint) : \(settings.database) · IAM \(settings.awsProfile.isEmpty ? "default" : settings.awsProfile)"
        }
    }
}

private struct ImportURLView: View {
    let onFinish: (ConnectionURL.Parsed?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("URL di connessione").font(.headline)
            TextField("postgresql://user@localhost/databasename", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
            if !text.isEmpty, ConnectionURL.parse(text) == nil {
                Text("URL non valido").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Annulla") { onFinish(nil) }.keyboardShortcut(.cancelAction)
                Button("Importa") { onFinish(ConnectionURL.parse(text)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ConnectionURL.parse(text) == nil)
            }
        }
        .padding(20)
    }
}
