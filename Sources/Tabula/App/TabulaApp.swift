import AppKit
import SwiftUI
import TabulaCore

@main
struct TabulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        AppDelegate.tunnels = model.sessionFactory.tunnels
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("Benvenuto in Tabula", id: WindowID.welcome) {
            WelcomeView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 460)

        WindowGroup("Workspace", id: WindowID.workspace, for: WorkspaceTarget.self) { $target in
            if let target, let connection = model.connection(target.connectionID) {
                WorkspaceView(connection: connection, target: target)
                    .environment(model)
            } else {
                MissingConnectionView()
            }
        }
        .defaultSize(width: 1280, height: 800)
        // Sessions cannot survive a relaunch, so restored windows would only be empty shells.
        .restorationBehavior(.disabled)
        .commands { WorkspaceCommands() }
    }
}

/// A workspace whose connection was deleted closes itself instead of lingering empty.
private struct MissingConnectionView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
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
        terminateGracefullyOnSIGTERM()
    }

    private var signalSource: DispatchSourceSignal?

    /// `pkill` and logout send SIGTERM: route it through NSApp.terminate so
    /// applicationWillTerminate closes the tunnels.
    private func terminateGracefullyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Tunnels started by Tabula must not outlive it.
    func applicationWillTerminate(_ notification: Notification) {
        guard let tunnels = Self.tunnels else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await tunnels.releaseAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    nonisolated(unsafe) static var tunnels: TunnelManager?
}
