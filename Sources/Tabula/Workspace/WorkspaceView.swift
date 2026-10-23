import SwiftUI
import TabulaCore

struct WorkspaceView: View {
    @Environment(AppModel.self) private var appModel
    let connection: ConnectionConfig
    let target: WorkspaceTarget
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                WorkspaceContent(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowConfigurator { WorkspaceWindows.adopt($0, inNewWindow: target.inNewWindow) })
        .task {
            guard model == nil else { return }
            let workspace = WorkspaceModel(connection: connection, appModel: appModel)
            model = workspace
            appModel.register(workspace, target: target.id)
            await workspace.start()
        }
        .onDisappear {
            appModel.unregister(target: target.id)
            guard let model else { return }
            Task { await model.close() }
        }
        // The window title becomes the native tab label; the toolbar shows the status pill instead.
        .navigationTitle(model?.connection.name ?? connection.name)
        .toolbar(removing: .title)
    }
}

private struct WorkspaceContent: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 400)
        } detail: {
            VStack(spacing: 0) {
                connectionBanner
                if !model.tabs.isEmpty { TabBar(model: model) }
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { WorkspaceToolbar(model: model) }
        .focusedSceneValue(\.workspace, model)
        .sheet(item: $model.pendingConfirmation) { confirmation in
            ConfirmationSheet(confirmation: confirmation, connection: model.connection)
        }
        .sheet(item: $model.presentedSheet) { sheet in
            switch sheet {
            case .connections: OpenConnectionSheet(workspace: model)
            case .databases: OpenDatabaseSheet(model: model)
            }
        }
        .sheet(isPresented: Binding(get: { model.phase == .needsPassword }, set: { _ in })) {
            PasswordPrompt(connection: model.connection) { password in
                Task { await model.providePassword(password) }
            }
        }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        if case .failed(let message) = model.phase {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).textSelection(.enabled).font(.callout)
                Spacer()
                Button("Riprova") { Task { await model.connect() } }
            }
            .padding(10)
            .background(.orange.opacity(0.12))
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.selectedTab {
        case .table(let table): TableTabView(table: table)
        case .query(let query): QueryTabView(query: query)
        case nil: EmptyWorkspaceView(model: model)
        }
    }
}

private struct EmptyWorkspaceView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                ShortcutHint(keys: "⌘K", text: "Apri un'altra connessione")
                if !model.isDSQL { ShortcutHint(keys: "⌘D", text: "Apri un database") }
                ShortcutHint(keys: "⌘T", text: "Nuova query SQL")
                ShortcutHint(keys: "⌘P", text: "Cerca una tabella nella barra laterale")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ShortcutHint: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.callout)
        .frame(width: 300)
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
