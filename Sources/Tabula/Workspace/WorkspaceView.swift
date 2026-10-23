import SwiftUI
import TabulaCore

struct WorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    let connection: ConnectionConfig
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                WorkspaceContent(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            let workspace = WorkspaceModel(connection: connection, appModel: appModel)
            model = workspace
            await workspace.start()
        }
        .onDisappear {
            guard let model else { return }
            Task { await model.close() }
        }
        .navigationTitle(connection.name)
        .navigationSubtitle("\(connection.kind.driverName) · \(connection.database)")
    }
}

private struct WorkspaceContent: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } detail: {
            VStack(spacing: 0) {
                connectionBanner
                TabBar(model: model)
                Divider()
                HSplitView {
                    VSplitView {
                        tabContent.frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                        if model.showsConsole {
                            ConsoleLogView(entries: model.log).frame(minHeight: 100, idealHeight: 160, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    if model.showsRowDetail, case .table(let table) = model.selectedTab {
                        RowDetailView(table: table).frame(minWidth: 220, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBarView(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbar }
        .focusedSceneValue(\.workspace, model)
        .sheet(item: $model.pendingConfirmation) { confirmation in
            ConfirmationSheet(confirmation: confirmation, connection: model.connection)
        }
        .sheet(isPresented: Binding(get: { model.phase == .needsPassword }, set: { _ in })) {
            PasswordPrompt(connection: model.connection) { password in
                Task { await model.providePassword(password) }
            }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch model.phase {
        case .connecting:
            HStack {
                ProgressView().controlSize(.small)
                Text(model.isDSQL ? "Genero il token IAM e mi connetto…" : "Connessione in corso…")
                Spacer()
            }
            .padding(8)
            .background(.bar)
        case .failed(let message):
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).textSelection(.enabled).font(.callout)
                Spacer()
                Button("Riprova") { Task { await model.connect() } }
            }
            .padding(10)
            .background(.orange.opacity(0.12))
        case .connected, .needsPassword:
            EmptyView()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.selectedTab {
        case .table(let table): TableTabView(table: table)
        case .query(let query): QueryTabView(query: query)
        case nil:
            ContentUnavailableView {
                Label("Nessuna tabella aperta", systemImage: "tablecells")
            } description: {
                Text("Scegli una tabella a sinistra o apri un editor SQL con ⌘T")
            } actions: {
                Button("Nuova query") { model.newQueryTab() }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionChip(connection: model.connection, phase: model.phase)
        }
        ToolbarItemGroup {
            Button { Task { await model.refreshAll() } } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                .help("Aggiorna (⌘R)")
            Button { model.newQueryTab() } label: { Label("SQL", systemImage: "terminal") }
                .help("Nuovo editor SQL (⌘T)")
            Menu {
                Picker("Modalità sicura", selection: $model.safeMode) {
                    ForEach(SafeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Riconnetti (nuovo token)") { Task { await model.reconnect() } }
            } label: {
                Label("Sicurezza", systemImage: model.safeMode == .silent ? "lock.open" : "lock.fill")
            }
            Toggle(isOn: $model.showsConsole) { Label("Console", systemImage: "list.bullet.rectangle") }
                .help("Log delle query")
            Toggle(isOn: $model.showsRowDetail) { Label("Dettaglio", systemImage: "sidebar.right") }
                .help("Dettaglio riga")
        }
    }
}

private struct ConnectionChip: View {
    let connection: ConnectionConfig
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(connection.name).font(.callout.weight(.medium))
            TagBadge(tag: connection.tag)
        }
        .padding(.horizontal, 8)
    }

    private var dotColor: Color {
        switch phase {
        case .connected: .green
        case .connecting, .needsPassword: .yellow
        case .failed: .red
        }
    }
}

private struct ConfirmationSheet: View {
    let confirmation: PendingConfirmation
    let connection: ConnectionConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.shield.fill").font(.title).foregroundStyle(connection.tag.color)
                VStack(alignment: .leading) {
                    Text("Eseguire su \(connection.name)?").font(.headline)
                    Text("Connessione \(connection.tag.title) in modalità sicura").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(confirmation.statements.joined(separator: ";\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520, height: 180)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Annulla") { confirmation.resume(false) }.keyboardShortcut(.cancelAction)
                Button("Esegui") { confirmation.resume(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct PasswordPrompt: View {
    let connection: ConnectionConfig
    let onSubmit: (String) -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password per \(connection.user)@\(connection.host)").font(.headline)
            SecureField("Password", text: $password).frame(width: 320)
            HStack {
                Spacer()
                Button("Connetti") { onSubmit(password) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
