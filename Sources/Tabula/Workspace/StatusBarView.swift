import SwiftUI
import TabulaCore

struct StatusBarView: View {
    let model: WorkspaceModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                Text("\(model.connection.kind.driverName) : \(model.connection.host) : \(model.connection.database)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.isDSQL { tokenStatus(now: context.date) }
                if let openedAt = model.status.openedAt {
                    Label("connessa da \(duration(from: openedAt, to: context.date))", systemImage: "bolt.horizontal")
                }
                if model.status.reconnectCount > 0 {
                    Label("\(model.status.reconnectCount) riconnessioni", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func tokenStatus(now: Date) -> some View {
        if let expiresAt = model.status.tokenExpiresAt {
            let remaining = expiresAt.timeIntervalSince(now)
            Label(
                remaining > 0 ? "token IAM valido ancora \(format(remaining))" : "token scaduto: il prossimo verrà generato alla riconnessione",
                systemImage: "key.horizontal"
            )
            .help("Il token serve solo ad aprire la connessione: alla scadenza la connessione resta attiva, e Tabula ne genera uno nuovo quando deve riconnettersi.")
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        format(end.timeIntervalSince(start))
    }

    private func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

struct ConsoleLogView: View {
    let entries: [LogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            List(entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.tertiary)
                    Text(entry.sql).textSelection(.enabled).lineLimit(4)
                    Spacer()
                    switch entry.outcome {
                    case .success(let summary): Text(summary).foregroundStyle(.secondary)
                    case .failure(let message): Text(message).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .id(entry.id)
            }
            .onChange(of: entries.count) {
                if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
