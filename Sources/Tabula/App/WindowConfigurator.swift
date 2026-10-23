import AppKit
import SwiftUI

/// Gives SwiftUI scenes access to their NSWindow.
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
    /// Connections live in the left rail, so the window never joins a native tab group.
    static func configure(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = Theme.surfaceNS
    }
}
