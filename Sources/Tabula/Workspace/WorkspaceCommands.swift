import SwiftUI

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Query") { workspace?.newQueryTab() }
                .keyboardShortcut("t")
                .disabled(workspace == nil)
            Button("Close Tab") {
                guard let workspace, let id = workspace.selectedTabID else { return }
                workspace.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(workspace?.selectedTabID == nil)
            Button("Open Connection…") {
                if let workspace { workspace.presentedSheet = .connections } else { openWindow(id: WindowID.welcome) }
            }
            .keyboardShortcut("k")
            Button("Open Database…") { workspace?.presentedSheet = .databases }
                .keyboardShortcut("d")
                .disabled(workspace == nil || workspace?.isDSQL == true)
            Button("Manage Connections") { openWindow(id: WindowID.welcome) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }
        CommandMenu("Connection") {
            Group {
            Button("Refresh") { Task { await workspace?.refreshAll() } }
                .keyboardShortcut("r")
            Button("Reconnect (new token)") { Task { await workspace?.reconnect() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Search table") { workspace?.tableSearchFocusRequest += 1 }
                .keyboardShortcut("p")
            Button("Filters") {
                if case .table(let table) = workspace?.selectedTab { table.showsFilters.toggle() }
            }
            .keyboardShortcut("f")
            Button("Show/hide console") { workspace?.showsConsole.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Show/hide row detail") { workspace?.showsRowDetail.toggle() }
                .keyboardShortcut("]", modifiers: [.command])
            }
            .disabled(workspace == nil)
        }
    }
}
