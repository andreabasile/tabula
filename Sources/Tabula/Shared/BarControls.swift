import SwiftUI

/// Small text button for the bottom bars ("+ Row", "Delete", "Filters"); `isOn` tints it like a toggle.
struct BarTextButton: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(isEnabled ? (isOn ? Color.accentColor : .primary) : Color.secondary.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 14).padding(.horizontal, 4)
    }
}

/// The bottom-bar controls of a grid with unsaved edits: the count (click it for the SQL), discard, save.
struct PendingChangesControls: View {
    let count: Int
    let statements: [String]
    let onDiscard: () -> Void
    let onSave: () -> Void
    @State private var showsSQL = false

    var body: some View {
        Button("\(count) changes") { showsSQL = true }
            .buttonStyle(.link)
            .popover(isPresented: $showsSQL, arrowEdge: .top) {
                ScrollView {
                    Text(statements.joined(separator: "\n"))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
                .frame(width: 520, height: 220)
            }
        Button("Discard", action: onDiscard)
            .controlSize(.small)
        Button("Save ⌘S", action: onSave)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut("s")
        BarDivider()
    }
}
