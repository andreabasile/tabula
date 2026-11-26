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

    /// Runs again on updates: SwiftUI may replace the window's delegate, and `configure` must be idempotent.
    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { configure(window) }
    }
}

@MainActor
enum WorkspaceWindows {
    private static var closeGuardKey: UInt8 = 0

    /// Connections live in the left rail, so the window never joins a native tab group.
    static func configure(_ window: NSWindow) {
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = Theme.surfaceNS
        guard !(window.delegate is WindowCloseGuard) else { return }
        let closeGuard = WindowCloseGuard(original: window.delegate) {
            AppDelegate.model?.workspaces.contains(where: \.hasUnsavedChanges) != true || UnsavedChanges.confirmDiscard()
        }
        // window.delegate is weak: the window itself keeps the guard alive.
        objc_setAssociatedObject(window, &closeGuardKey, closeGuard, .OBJC_ASSOCIATION_RETAIN)
        window.delegate = closeGuard
    }
}

/// SwiftUI owns the window's delegate and has no way to refuse a close (⌘W, the red button): this
/// proxy answers windowShouldClose and forwards every other delegate message to SwiftUI's delegate.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    /// Set once in init; read from responds(to:)/forwardingTarget(for:), which are not main-actor bound.
    private nonisolated(unsafe) weak var original: NSWindowDelegate?
    private let mayClose: @MainActor () -> Bool

    init(original: NSWindowDelegate?, mayClose: @escaping @MainActor () -> Bool) {
        self.original = original
        self.mayClose = mayClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Ask first: SwiftUI's own hook runs only for a close that will really happen.
        guard mayClose() else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}
