import AppKit

/// Asks before an action throws away grid edits that were not saved with ⌘S.
@MainActor
enum UnsavedChanges {
    static func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert.informativeText = String(localized: "Your edits have not been saved with ⌘S and will be lost.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
