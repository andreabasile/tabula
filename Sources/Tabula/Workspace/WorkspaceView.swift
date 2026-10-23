import SwiftUI
import TabulaCore

/// The single workspace window: TablePlus's rail of open connections on the left,
/// the active connection's sidebar and tabs on the right.
struct WorkspaceShell: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 0) {
            ConnectionRail()
            Rectangle().fill(Theme.border).frame(width: 1)
            if let workspace = appModel.activeWorkspace {
                WorkspaceContent(model: workspace)
                    .id(workspace.id)
            } else {
                Theme.surface
            }
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .background(WindowConfigurator(configure: WorkspaceWindows.configure))
        .navigationTitle(appModel.activeWorkspace?.connection.name ?? "Tabula")
        .toolbar(removing: .title)
        .onAppear(perform: showWelcomeIfEmpty)
        .onChange(of: appModel.workspaces.isEmpty) { showWelcomeIfEmpty() }
        // Closing the window closes every connection it holds, as TablePlus does.
        .onDisappear { appModel.closeAllWorkspaces() }
    }

    private func showWelcomeIfEmpty() {
        guard appModel.workspaces.isEmpty else { return }
        dismissWindow(id: WindowID.workspace)
        openWindow(id: WindowID.welcome)
    }
}

/// The column of open connections: a database icon tinted by the tag, the name below.
private struct ConnectionRail: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(appModel.workspaces.enumerated()), id: \.element.id) { index, workspace in
                        RailItem(workspace: workspace, isActive: workspace.id == appModel.activeWorkspace?.id) {
                            appModel.activeWorkspaceID = workspace.id
                        } onClose: {
                            appModel.closeWorkspace(workspace.id)
                        }
                        .background {
                            // ⌘1…⌘9 jump to a connection, like browser tabs.
                            if index < 9 {
                                Button("") { appModel.activeWorkspaceID = workspace.id }
                                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                                    .hidden()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button { appModel.activeWorkspace?.presentedSheet = .connections } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Apri un'altra connessione (⌘K)")
            .padding(.bottom, 6)
        }
        .frame(width: 76)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct RailItem: View {
    let workspace: WorkspaceModel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 5) {
                Image(systemName: "cylinder")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(iconColor)
                    .overlay(alignment: .bottomTrailing) { statusBadge }
                Text(workspace.connection.name)
                    .font(.system(size: 10))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background(isActive ? Theme.surface : (isHovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Chiudi la connessione")
            }
        }
        .onHover { isHovering = $0 }
        .help(tooltip)
        .contextMenu {
            Button("Riconnetti") { Task { await workspace.reconnect() } }
            Divider()
            Button("Chiudi", action: onClose)
        }
    }

    private var iconColor: Color {
        workspace.connection.tag == .local ? .green : workspace.connection.tag.color
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch workspace.phase {
        case .connecting:
            ProgressView().controlSize(.mini).offset(x: 6, y: 4)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange).offset(x: 5, y: 3)
        default:
            EmptyView()
        }
    }

    private var tooltip: String {
        let database = workspace.currentDatabase.isEmpty ? workspace.connection.database : workspace.currentDatabase
        return "Driver: \(workspace.connection.kind.driverName)\nNome: \(workspace.connection.name)\nDatabase: \(database)"
    }
}

private struct WorkspaceContent: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 190, idealWidth: 260, maxWidth: 480, maxHeight: .infinity)
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
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { WorkspaceToolbar(model: model) }
        .toolbarBackground(Theme.surface, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
        if model.phase == .connecting, model.hasPreConnectScript {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Eseguo lo script prima della connessione e attendo il tunnel…").font(.callout)
                Spacer()
            }
            .padding(8)
            .background(Theme.selection)
        }
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
        .background(Theme.surface)
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
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
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
