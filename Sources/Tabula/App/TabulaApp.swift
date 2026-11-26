import AppKit
import SwiftUI
import TabulaCore

@main
struct TabulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        AppDelegate.model = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("Welcome to Tabula", id: WindowID.welcome) {
            WelcomeView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 760, height: 460)

        // One window for every open connection, switched from the left rail as in TablePlus.
        Window(Text(verbatim: "Tabula"), id: WindowID.workspace) {
            WorkspaceShell()
                .environment(model)
        }
        .defaultSize(width: 1280, height: 800)
        // Sessions cannot survive a relaunch, so a restored window would only be an empty shell.
        .restorationBehavior(.disabled)
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
        terminateGracefullyOnSIGTERM()
        UpdateCheck.start()
    }

    private var signalSource: DispatchSourceSignal?

    /// `pkill` and logout send SIGTERM: route it through NSApp.terminate so
    /// applicationWillTerminate closes the tunnels.
    private func terminateGracefullyOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // The source fires on the main queue.
        source.setEventHandler {
            MainActor.assumeIsolated {
                // Nobody may be there to answer a prompt (pkill, scripts): quit without asking.
                Self.isQuittingFromSignal = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        signalSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting would drop grid edits not saved with ⌘S: ask first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isQuittingFromSignal, Self.model?.workspaces.contains(where: \.hasUnsavedChanges) == true else { return .terminateNow }
        return UnsavedChanges.confirmDiscard() ? .terminateNow : .terminateCancel
    }

    /// Tunnels started by Tabula must not outlive it.
    func applicationWillTerminate(_ notification: Notification) {
        guard let tunnels = Self.model?.sessionFactory.tunnels else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await tunnels.releaseAll()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    @MainActor static var model: AppModel?
    @MainActor private static var isQuittingFromSignal = false
}
