import SwiftUI

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Nuova query") { workspace?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Chiudi tab") {
                guard let workspace, let id = workspace.selectedTabID else { return }
                workspace.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTabID == nil)
            Button("Apri connessione…") { openWindow(id: WindowID.welcome) }
                .keyboardShortcut("k")
        }
        CommandMenu("Connessione") {
            Group {
            Button("Aggiorna") { Task { await workspace?.refreshAll() } }
                .keyboardShortcut("r")
            Button("Riconnetti (nuovo token)") { Task { await workspace?.reconnect() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Filtri") {
                if case .table(let table) = workspace?.selectedTab { table.showsFilters.toggle() }
            }
            .keyboardShortcut("f")
            Button("Mostra/nascondi console") { workspace?.showsConsole.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Mostra/nascondi dettaglio riga") { workspace?.showsRowDetail.toggle() }
                .keyboardShortcut("]", modifiers: [.command])
            }
            .disabled(workspace == nil)
        }
    }
}
