import AppKit
import SwiftUI
import TabulaCore

@main
struct TabulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Benvenuto in Tabula", id: WindowID.welcome) {
            WelcomeView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 460)

        WindowGroup("Workspace", id: WindowID.workspace, for: UUID.self) { $connectionID in
            if let connectionID, let connection = model.connection(connectionID) {
                WorkspaceView(connection: connection)
                    .environment(model)
            } else {
                ContentUnavailableView("Connessione non trovata", systemImage: "externaldrive.badge.xmark")
            }
        }
        .defaultSize(width: 1280, height: 800)
        .commands { WorkspaceCommands() }
    }
}

enum WindowID {
    static let welcome = "welcome"
    static let workspace = "workspace"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from `swift run` the binary is not a bundle; make it a regular app anyway.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        WindowSnapshotter.startIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
