import AppKit
import SwiftUI

/// Gives SwiftUI scenes access to their NSWindow, which is needed for native tabs.
struct WindowConfigurator: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
enum WorkspaceWindows {
    static let tabbingIdentifier = "tabula.workspace"

    /// Like TablePlus: a new connection lands as a tab of the frontmost workspace window.
    static func adopt(_ window: NSWindow, inNewWindow: Bool) {
        window.tabbingIdentifier = tabbingIdentifier
        window.tabbingMode = inNewWindow ? .disallowed : .preferred
        window.titlebarSeparatorStyle = .line
        guard !inNewWindow,
              window.tabGroup?.windows.count ?? 1 <= 1,
              let host = NSApp.orderedWindows.first(where: { $0 !== window && $0.tabbingIdentifier == tabbingIdentifier && $0.isVisible })
        else { return }
        host.addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .preferred
    }
}
