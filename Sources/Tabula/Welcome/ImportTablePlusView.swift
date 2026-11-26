import SwiftUI
import TabulaCore
import UniformTypeIdentifiers

/// Import from a TablePlus export: pick the file, type its password, review, import.
struct ImportTablePlusView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var password = ""
    @State private var preview: TablePlusImport?
    @State private var selected: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var choosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Connections from TablePlus").font(.headline)
            Text("In TablePlus: File › Export Connections. You need the password chosen during export.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(fileURL?.lastPathComponent ?? String(localized: "No file chosen"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(fileURL == nil ? .secondary : .primary)
                Spacer()
                Button("Choose File…") { choosingFile = true }
            }
            HStack {
                SecureField("Export password", text: $password)
                    .onSubmit(read)
                Button("Read", action: read).disabled(fileURL == nil)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            if let preview { previewList(preview) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count)") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result {
                fileURL = url
                preview = nil
            }
        }
    }

    private func previewList(_ preview: TablePlusImport) -> some View {
        List {
            ForEach(preview.connections) { item in
                let isDuplicate = model.isAlreadySaved(item.connection)
                HStack(alignment: .top) {
                    Toggle(isOn: binding(for: item.id)) {}.labelsHidden()
                    DriverIcon(kind: item.connection.kind, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.connection.name).fontWeight(.medium)
                            TagBadge(tag: item.connection.tag)
                            if isDuplicate { Text("already exists").font(.caption2).foregroundStyle(.orange) }
                        }
                        let address = "\(item.connection.host):\(port(item.connection)) · \(item.connection.user)"
                        Text(item.password == nil ? address : String(localized: "\(address) · password included"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(item.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            ForEach(preview.skipped, id: \.name) { skipped in
                Label(skipped.name + ": " + skipped.reason, systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 260)
    }

    private func port(_ connection: ConnectionConfig) -> String {
        if case .postgres(let settings) = connection.kind { return String(settings.port) }
        return "5432"
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private func read() {
        guard let fileURL else { return }
        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let result = try TablePlusImporter.read(Data(contentsOf: fileURL), password: password)
            preview = result
            selected = Set(result.connections.filter { !model.isAlreadySaved($0.connection) }.map(\.id))
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func importSelected() {
        guard let preview else { return }
        do {
            try model.importConnections(preview.connections.filter { selected.contains($0.id) })
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
