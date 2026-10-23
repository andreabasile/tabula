import AppKit

/// Development aid: with TABULA_SNAPSHOT_DIR set, saves a PNG of every window every
/// few seconds, so the UI can be checked without screen-recording permissions.
@MainActor
enum WindowSnapshotter {
    static func startIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_SNAPSHOT_DIR"] else { return }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { capture(into: URL(fileURLWithPath: directory)) }
        }
    }

    private static func capture(into directory: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let name = window.title.isEmpty ? "window-\(index)" : window.title
            let url = directory.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
