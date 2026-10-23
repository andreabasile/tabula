import Foundation

public protocol PortProbing: Sendable {
    func isOpen(host: String, port: Int) async -> Bool
}

public protocol RunningScript: AnyObject, Sendable {
    var isRunning: Bool { get }
    var exitCode: Int32? { get }
    var output: String { get }
    func terminate()
}

public protocol ScriptLaunching: Sendable {
    func launch(_ script: String) throws -> RunningScript
}

public struct TunnelEvent: Sendable {
    public enum Kind: Sendable { case alreadyOpen, started, ready, stopped }
    public let kind: Kind
    public let endpoint: String
}

/// Runs pre-connect scripts and keeps the tunnels they open alive while some window
/// uses them. Keyed by local endpoint, so connections sharing a tunnel share one process.
public actor TunnelManager {
    private struct Tunnel {
        var process: RunningScript
        var owners: Set<UUID>
    }

    private let launcher: ScriptLaunching
    private let probe: PortProbing
    private let pollInterval: Duration
    private var tunnels: [String: Tunnel] = [:]
    private var listener: (@Sendable (TunnelEvent) -> Void)?

    public init(launcher: ScriptLaunching, probe: PortProbing, pollInterval: Duration = .milliseconds(250)) {
        self.launcher = launcher
        self.probe = probe
        self.pollInterval = pollInterval
    }

    public func onEvent(_ listener: @escaping @Sendable (TunnelEvent) -> Void) {
        self.listener = listener
    }

    /// Makes sure the script's effect is in place before `owner` connects to host:port.
    public func prepare(_ script: PreConnectScript, host: String, port: Int, owner: UUID) async throws {
        guard !script.isEmpty else { return }
        if script.waitsForPort {
            try await openTunnel(script, host: host, port: port, owner: owner)
        } else {
            try await runToCompletion(script)
        }
    }

    /// The owner no longer needs its tunnels; a tunnel with no owners left is closed.
    public func release(owner: UUID) {
        for (endpoint, var tunnel) in tunnels where tunnel.owners.contains(owner) {
            tunnel.owners.remove(owner)
            if tunnel.owners.isEmpty {
                tunnel.process.terminate()
                tunnels[endpoint] = nil
                listener?(TunnelEvent(kind: .stopped, endpoint: endpoint))
            } else {
                tunnels[endpoint] = tunnel
            }
        }
    }

    public func releaseAll() {
        tunnels.values.forEach { $0.process.terminate() }
        tunnels = [:]
    }

    private func openTunnel(_ script: PreConnectScript, host: String, port: Int, owner: UUID) async throws {
        let endpoint = "\(host):\(port)"
        if await probe.isOpen(host: host, port: port) {
            tunnels[endpoint]?.owners.insert(owner)
            listener?(TunnelEvent(kind: .alreadyOpen, endpoint: endpoint))
            return
        }
        let process = try reuseOrLaunch(script, endpoint: endpoint, owner: owner)
        let deadline = ContinuousClock.now + .seconds(script.timeoutSeconds)
        while ContinuousClock.now < deadline {
            if await probe.isOpen(host: host, port: port) {
                listener?(TunnelEvent(kind: .ready, endpoint: endpoint))
                return
            }
            // A script that exits 0 may have started the tunnel in background: keep probing.
            if let code = process.exitCode, code != 0 {
                tunnels[endpoint] = nil
                throw PreConnectScriptError.scriptFailed(exitCode: code, output: process.output)
            }
            try await Task.sleep(for: pollInterval)
        }
        if tunnels[endpoint]?.process === process { tunnels[endpoint] = nil }
        process.terminate()
        throw PreConnectScriptError.portNeverOpened(host: host, port: port, seconds: script.timeoutSeconds, output: process.output)
    }

    private func reuseOrLaunch(_ script: PreConnectScript, endpoint: String, owner: UUID) throws -> RunningScript {
        if var existing = tunnels[endpoint], existing.process.isRunning {
            existing.owners.insert(owner)
            tunnels[endpoint] = existing
            return existing.process
        }
        let process = try launcher.launch(script.script)
        tunnels[endpoint] = Tunnel(process: process, owners: [owner])
        listener?(TunnelEvent(kind: .started, endpoint: endpoint))
        return process
    }

    private func runToCompletion(_ script: PreConnectScript) async throws {
        let process = try launcher.launch(script.script)
        let deadline = ContinuousClock.now + .seconds(script.timeoutSeconds)
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                process.terminate()
                throw PreConnectScriptError.scriptTimedOut(seconds: script.timeoutSeconds, output: process.output)
            }
            try await Task.sleep(for: pollInterval)
        }
        if let code = process.exitCode, code != 0 {
            throw PreConnectScriptError.scriptFailed(exitCode: code, output: process.output)
        }
    }
}

/// Runs the tunnel script before every (re)connect, so a tunnel dropped by SSM for
/// inactivity is reopened transparently on the next query.
public struct TunnelingCredentialsProvider: CredentialsProviding {
    private let base: CredentialsProviding
    private let script: PreConnectScript
    private let tunnels: TunnelManager
    private let owner: UUID

    public init(base: CredentialsProviding, script: PreConnectScript, tunnels: TunnelManager, owner: UUID) {
        self.base = base
        self.script = script
        self.tunnels = tunnels
        self.owner = owner
    }

    public func credentials() async throws -> ConnectionCredentials {
        let credentials = try await base.credentials()
        try await tunnels.prepare(script, host: credentials.host, port: credentials.port, owner: owner)
        return credentials
    }

    public func invalidate() async {
        await base.invalidate()
    }
}
