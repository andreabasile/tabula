import SwiftUI
import TabulaCore

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
