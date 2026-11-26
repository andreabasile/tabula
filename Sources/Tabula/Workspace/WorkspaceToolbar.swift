import SwiftUI
import TabulaCore

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.presentedSheet = .connections } label: { Label("Connections", systemImage: "powerplug") }
                .help("Open another connection (⌘K)")
            if !model.isDSQL {
                Button { model.presentedSheet = .databases } label: { Label("Database", systemImage: "cylinder.split.1x2") }
                    .help("Open a database (⌘D)")
            }
            Button { model.newQueryTab() } label: { Label("SQL", systemImage: "chevron.left.forwardslash.chevron.right") }
                .help("New SQL editor (⌘T)")
            Button { Task { await model.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh (⌘R)")
        }
        ToolbarItem(placement: .principal) {
            StatusPill(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Safe mode", selection: $model.safeMode) {
                    ForEach(SafeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Security", systemImage: model.safeMode == .silent ? "lock.open" : "lock.fill")
            }
            .help("Safe mode")
            Toggle(isOn: $model.showsConsole) { Label("Console", systemImage: "rectangle.bottomthird.inset.filled") }
                .help("Query log (⇧⌘C)")
            Toggle(isOn: $model.showsRowDetail) { Label("Detail", systemImage: "sidebar.right") }
                .help("Row detail (⌘])")
        }
    }
}

/// TablePlus's address-bar-like box: driver, connection, database, tinted by the
/// environment tag so production is impossible to miss.
struct StatusPill: View {
    let model: WorkspaceModel
    @State private var showsInfo = false

    var body: some View {
        Button { showsInfo.toggle() } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isDSQL, model.phase == .connected {
                    TokenBadge(expiresAt: model.status.tokenExpiresAt)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minWidth: 420, maxWidth: 900, minHeight: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
            ConnectionInfoView(model: model)
        }
    }

    /// "TESTING | PostgreSQL 16.11 : TLSv1.3 : shop TEST : shop : SQL Query", as TablePlus.
    private var title: String {
        let connection = model.connection
        let state = switch model.phase {
        case .connecting: " — " + String(localized: "connection…")
        case .failed: " — " + String(localized: "error")
        default: ""
        }
        let server = [model.status.server.version.map { "\(connection.kind.driverName) \($0)" } ?? connection.kind.driverName, model.status.server.tlsProtocol]
        let parts = server.compactMap { $0 } + [connection.name, model.currentDatabase, model.selectedTab?.title].compactMap { $0 }
        return "\(connection.tag.title.uppercased()) | " + parts.joined(separator: " : ") + state
    }

    private var isBusy: Bool { model.phase == .connecting || model.runningQueries > 0 }

    private var isTinted: Bool { model.connection.tag != .local }

    /// A pale wash of the tag colour, like TablePlus, rather than a saturated fill.
    private var background: Color {
        isTinted ? model.connection.tag.color.opacity(0.28) : Color(nsColor: .controlBackgroundColor)
    }

    private var dotColor: Color {
        switch model.phase {
        case .connected: isTinted ? model.connection.tag.color : .green
        case .connecting, .needsPassword: .yellow
        case .failed: .orange
        }
    }
}

private struct TokenBadge: View {
    let expiresAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let expiresAt {
                let minutes = max(0, Int(expiresAt.timeIntervalSince(context.date) / 60))
                Label("\(minutes) min", systemImage: "key.horizontal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .help("Validity of the current IAM token: it is only needed to open new connections, and Tabula regenerates it automatically.")
            }
        }
    }
}

/// The popover behind the status pill: connection details, token timing, reconnect.
struct ConnectionInfoView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DriverIcon(kind: model.connection.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.connection.name).font(.headline)
                        TagBadge(tag: model.connection.tag)
                    }
                    Text(model.connection.kind.driverName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Host", model.connection.host)
                row("User", model.connection.user)
                row("Database", model.currentDatabase)
                if case .dsql(let settings) = model.connection.kind {
                    row("AWS profile", settings.awsProfile.isEmpty ? String(localized: "default chain") : settings.awsProfile)
                    row("Region", settings.resolvedRegion ?? "—")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        if let openedAt = model.status.openedAt {
                            row("Connected for", Self.duration(context.date.timeIntervalSince(openedAt)))
                        }
                        if let issued = model.status.tokenIssuedAt, let expires = model.status.tokenExpiresAt {
                            row("Token generated", issued.formatted(date: .omitted, time: .standard))
                            row("Token valid", expires > context.date ? String(localized: "\(Self.duration(expires.timeIntervalSince(context.date))) left") : String(localized: "expired (renewed on next connection)"))
                        }
                        row("Reconnects", String(model.status.reconnectCount))
                    }
                }
                .gridCellColumns(2)
            }
            .font(.callout)
            if model.isDSQL {
                Text("The IAM token is only needed to open the connection. Tabula generates a new one on every reconnect and recreates the connection after 55 minutes, before the DSQL limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reconnect") { Task { await model.reconnect() } }
                Button("Disconnect") { Task { await model.disconnect() } }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}
