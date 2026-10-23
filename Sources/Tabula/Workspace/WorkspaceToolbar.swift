import SwiftUI
import TabulaCore

struct WorkspaceToolbar: ToolbarContent {
    @Bindable var model: WorkspaceModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.presentedSheet = .connections } label: { Label("Connessioni", systemImage: "powerplug") }
                .help("Apri un'altra connessione (⌘K)")
            if !model.isDSQL {
                Button { model.presentedSheet = .databases } label: { Label("Database", systemImage: "cylinder.split.1x2") }
                    .help("Apri un database (⌘D)")
            }
            Button { model.newQueryTab() } label: { Label("SQL", systemImage: "chevron.left.forwardslash.chevron.right") }
                .help("Nuovo editor SQL (⌘T)")
            Button { Task { await model.refreshAll() } } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }
                .help("Aggiorna (⌘R)")
        }
        ToolbarItem(placement: .principal) {
            StatusPill(model: model)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Modalità sicura", selection: $model.safeMode) {
                    ForEach(SafeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sicurezza", systemImage: model.safeMode == .silent ? "lock.open" : "lock.fill")
            }
            .help("Modalità sicura")
            Toggle(isOn: $model.showsConsole) { Label("Console", systemImage: "rectangle.bottomthird.inset.filled") }
                .help("Log delle query (⇧⌘C)")
            Toggle(isOn: $model.showsRowDetail) { Label("Dettaglio", systemImage: "sidebar.right") }
                .help("Dettaglio riga (⌘])")
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
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isDSQL, model.phase == .connected {
                    TokenBadge(expiresAt: model.status.tokenExpiresAt, foreground: foreground)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minWidth: 360, maxWidth: 560, minHeight: 24)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
            ConnectionInfoView(model: model)
        }
    }

    private var title: String {
        let connection = model.connection
        let state = switch model.phase {
        case .connecting: " — connessione…"
        case .failed: " — errore"
        default: ""
        }
        return "\(connection.kind.driverName) : \(connection.name) : \(connection.database)\(state)"
    }

    private var isBusy: Bool { model.phase == .connecting || model.runningQueries > 0 }

    private var isTinted: Bool { model.connection.tag != .local }

    private var background: Color {
        isTinted ? model.connection.tag.color : Color(nsColor: .controlBackgroundColor)
    }

    private var foreground: Color { isTinted ? .white : .primary }

    private var dotColor: Color {
        switch model.phase {
        case .connected: isTinted ? .white : .green
        case .connecting, .needsPassword: .yellow
        case .failed: .orange
        }
    }
}

private struct TokenBadge: View {
    let expiresAt: Date?
    let foreground: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let expiresAt {
                let minutes = max(0, Int(expiresAt.timeIntervalSince(context.date) / 60))
                Label("\(minutes) min", systemImage: "key.horizontal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.85))
                    .help("Validità del token IAM corrente: serve solo ad aprire nuove connessioni, Tabula lo rigenera da sola.")
            }
        }
    }
}

/// The popover behind the status pill, after TablePlus's ConnectionInfoPopover.
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
                row("Utente", model.connection.user)
                row("Database", model.connection.database)
                if case .dsql(let settings) = model.connection.kind {
                    row("Profilo AWS", settings.awsProfile.isEmpty ? "catena predefinita" : settings.awsProfile)
                    row("Regione", settings.resolvedRegion ?? "—")
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        if let openedAt = model.status.openedAt {
                            row("Connessa da", Self.duration(context.date.timeIntervalSince(openedAt)))
                        }
                        if let issued = model.status.tokenIssuedAt, let expires = model.status.tokenExpiresAt {
                            row("Token generato", issued.formatted(date: .omitted, time: .standard))
                            row("Token valido", expires > context.date ? "ancora \(Self.duration(expires.timeIntervalSince(context.date)))" : "scaduto (rinnovo alla prossima connessione)")
                        }
                        row("Riconnessioni", String(model.status.reconnectCount))
                    }
                }
                .gridCellColumns(2)
            }
            .font(.callout)
            if model.isDSQL {
                Text("Il token IAM serve solo ad aprire la connessione. Tabula ne genera uno nuovo a ogni riconnessione e ricrea la connessione dopo 55 minuti, prima del limite di DSQL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Riconnetti") { Task { await model.reconnect() } }
                Button("Disconnetti") { Task { await model.disconnect() } }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func row(_ label: String, _ value: String) -> some View {
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
