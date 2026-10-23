import Foundation
import Testing
@testable import TabulaCore

struct TunnelManagerTests {
    let owner = UUID()
    let tunnelScript = PreConnectScript(script: "aws ssm start-session …", waitsForPort: true, timeoutSeconds: 2)

    @Test func skipsScriptWhenPortAlreadyOpen() async throws {
        let launcher = FakeLauncher()
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: 0), pollInterval: .milliseconds(5))
        try await manager.prepare(tunnelScript, host: "127.0.0.1", port: 15432, owner: owner)
        #expect(launcher.launched.isEmpty)
    }

    @Test func launchesAndWaitsForThePort() async throws {
        let launcher = FakeLauncher()
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: 4), pollInterval: .milliseconds(5))
        try await manager.prepare(tunnelScript, host: "127.0.0.1", port: 15432, owner: owner)
        #expect(launcher.launched == ["aws ssm start-session …"])
        #expect(launcher.processes.first?.isRunning == true)
    }

    @Test func failsWithScriptOutputWhenScriptExitsWithError() async {
        let launcher = FakeLauncher(exitCode: 255, output: "Token has expired")
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: nil), pollInterval: .milliseconds(5))
        await #expect(throws: PreConnectScriptError.scriptFailed(exitCode: 255, output: "Token has expired")) {
            try await manager.prepare(tunnelScript, host: "127.0.0.1", port: 15432, owner: owner)
        }
    }

    @Test func timesOutAndKillsTheScriptWhenPortNeverOpens() async {
        let launcher = FakeLauncher()
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: nil), pollInterval: .milliseconds(5))
        let quick = PreConnectScript(script: "sleep 100", waitsForPort: true, timeoutSeconds: 1)
        await #expect(throws: PreConnectScriptError.self) {
            try await manager.prepare(quick, host: "127.0.0.1", port: 1, owner: owner)
        }
        #expect(launcher.processes.first?.isRunning == false)
    }

    @Test func sharedTunnelClosesOnlyWhenLastOwnerReleases() async throws {
        let launcher = FakeLauncher()
        let probe = FakeProbe(openAfterChecks: 2)
        let manager = TunnelManager(launcher: launcher, probe: probe, pollInterval: .milliseconds(5))
        let other = UUID()
        try await manager.prepare(tunnelScript, host: "127.0.0.1", port: 15432, owner: owner)
        try await manager.prepare(tunnelScript, host: "127.0.0.1", port: 15432, owner: other)
        await manager.release(owner: owner)
        #expect(launcher.processes.first?.isRunning == true)
        await manager.release(owner: other)
        #expect(launcher.processes.first?.isRunning == false)
        #expect(launcher.launched.count == 1)
    }

    @Test func oneShotScriptsRunEveryTimeAndMustSucceed() async throws {
        let launcher = FakeLauncher(exitCode: 0, exitsImmediately: true)
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: 0), pollInterval: .milliseconds(5))
        let oneShot = PreConnectScript(script: "aws sso login --profile x", waitsForPort: false)
        try await manager.prepare(oneShot, host: "h", port: 1, owner: owner)
        try await manager.prepare(oneShot, host: "h", port: 1, owner: owner)
        #expect(launcher.launched.count == 2)
    }

    @Test func emptyScriptDoesNothing() async throws {
        let launcher = FakeLauncher()
        let manager = TunnelManager(launcher: launcher, probe: FakeProbe(openAfterChecks: nil))
        try await manager.prepare(PreConnectScript(script: "  \n"), host: "h", port: 1, owner: owner)
        #expect(launcher.launched.isEmpty)
    }

    @Test func realShellRunsScripts() async throws {
        let process = try SystemScriptLauncher().launch("echo tunnel-ok; exit 3")
        for _ in 0..<100 where process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(process.exitCode == 3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(process.output.contains("tunnel-ok"))
    }
}

struct PreConnectScriptStorageTests {
    @Test func oldFilesWithoutScriptStillDecode() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x","tag":"local","group":"","safeMode":"silent","kind":{"postgres":{"_0":{"host":"h","port":5432,"user":"u","database":"d","sslMode":"PREFERRED","passwordStorage":"keychain"}}}}]"#
        let connections = try JSONDecoder().decode([ConnectionConfig].self, from: Data(json.utf8))
        #expect(connections.first?.preConnectScript == nil)
    }

    @Test func scriptIsSavedWithTheConnection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-\(UUID().uuidString)/c.json")
        let store = ConnectionStore(fileURL: url, secrets: InMemorySecrets())
        let connection = ConnectionConfig(name: "prod", kind: .postgres(PostgresSettings(port: 15432)), preConnectScript: PreConnectScript(script: "bash ~/tunnel.sh"))
        try store.save(connection, password: nil)
        #expect(try store.load().first?.preConnectScript?.script == "bash ~/tunnel.sh")
    }

    @Test func tablePlusStartupScriptIsImported() throws {
        let json = #"[{"Name":"g","connections":[{"ConnectionName":"p","Driver":"PostgreSQL","DatabaseHost":"127.0.0.1","DatabasePort":15432,"StartupBashScript":"bash tunnel.sh"}],"groups":[]}]"#
        let imported = try TablePlusImporter.parse(json: Data(json.utf8))
        #expect(imported.connections.first?.connection.preConnectScript == PreConnectScript(script: "bash tunnel.sh"))
    }
}

// MARK: - Test doubles

final class FakeProbe: PortProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let openAfterChecks: Int?

    /// nil: never opens.
    init(openAfterChecks: Int?) {
        self.openAfterChecks = openAfterChecks
    }

    func isOpen(host: String, port: Int) async -> Bool {
        lock.withLock {
            defer { checks += 1 }
            guard let openAfterChecks else { return false }
            return checks >= openAfterChecks
        }
    }
}

final class FakeProcess: RunningScript, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private let code: Int32?
    let output: String

    init(exitCode: Int32?, output: String, exitsImmediately: Bool) {
        self.code = exitCode
        self.output = output
        self.running = !(exitsImmediately || exitCode != nil)
    }

    var isRunning: Bool { lock.withLock { running } }
    var exitCode: Int32? { lock.withLock { running ? nil : (code ?? 15) } }
    func terminate() { lock.withLock { running = false } }
}

final class FakeLauncher: ScriptLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String] = []
    private var started: [FakeProcess] = []
    private let exitCode: Int32?
    private let output: String
    private let exitsImmediately: Bool

    init(exitCode: Int32? = nil, output: String = "", exitsImmediately: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.exitsImmediately = exitsImmediately
    }

    var launched: [String] { lock.withLock { scripts } }
    var processes: [FakeProcess] { lock.withLock { started } }

    func launch(_ script: String) throws -> RunningScript {
        let process = FakeProcess(exitCode: exitCode, output: output, exitsImmediately: exitsImmediately)
        lock.withLock {
            scripts.append(script)
            started.append(process)
        }
        return process
    }
}

struct TunnelIntegrationTests {
    /// A real "tunnel": zsh starts a listener two levels deep, like aws → session-manager-plugin.
    @Test func opensWaitsAndTearsDownARealListener() async throws {
        let port = Int.random(in: 40000...49000)
        let manager = TunnelManager(launcher: SystemScriptLauncher(), probe: TCPPortProbe())
        let listener = "import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('127.0.0.1', \(port))); s.listen(50); time.sleep(60)"
        let script = PreConnectScript(script: "sleep 0.5; /bin/zsh -c \"python3 -c \\\"\(listener)\\\"\"", waitsForPort: true, timeoutSeconds: 10)
        let owner = UUID()

        #expect(await TCPPortProbe().isOpen(host: "127.0.0.1", port: port) == false)
        try await manager.prepare(script, host: "127.0.0.1", port: port, owner: owner)
        #expect(await TCPPortProbe().isOpen(host: "127.0.0.1", port: port))

        await manager.release(owner: owner)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await TCPPortProbe().isOpen(host: "127.0.0.1", port: port) == false)
    }
}
