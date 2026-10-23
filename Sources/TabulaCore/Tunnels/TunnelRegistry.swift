import Darwin
import Foundation

/// Remembers the process groups of running tunnel scripts on disk, so that tunnels left
/// behind by a crash or a forced quit are closed on the next launch.
public final class TunnelRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let processGroup: Int32
        public let script: String
    }

    public struct System: Sendable {
        /// Commands of the processes still in the group; empty when the group is gone.
        public var groupCommands: @Sendable (Int32) -> [String]
        public var killGroup: @Sendable (Int32) -> Void

        public static let live = System(
            groupCommands: { group in
                let pids = run("/usr/bin/pgrep", ["-g", String(group)]).split(whereSeparator: \.isNewline).map(String.init)
                return pids.map { run("/bin/ps", ["-o", "command=", "-p", $0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            },
            killGroup: { group in kill(-group, SIGTERM) }
        )

        private static func run(_ executable: String, _ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
    }

    private let fileURL: URL
    private let system: System
    private let lock = NSLock()

    public init(fileURL: URL, system: System = .live) {
        self.fileURL = fileURL
        self.system = system
    }

    public static func defaultFileURL() -> URL {
        ConnectionStore.defaultFileURL().deletingLastPathComponent().appendingPathComponent("tunnels.json")
    }

    public func record(processGroup: Int32, script: String) {
        update { $0.append(Entry(processGroup: processGroup, script: script)) }
    }

    public func forget(processGroup: Int32) {
        update { $0.removeAll { $0.processGroup == processGroup } }
    }

    /// Kills recorded groups that are still alive and still run the recorded script (a
    /// reused group id belonging to something else is left alone). Returns what it killed.
    @discardableResult
    public func reapOrphans() -> [Entry] {
        var killed: [Entry] = []
        update { entries in
            for entry in entries where isStillOurs(entry) {
                system.killGroup(entry.processGroup)
                killed.append(entry)
            }
            entries = []
        }
        return killed
    }

    private func isStillOurs(_ entry: Entry) -> Bool {
        let commands = system.groupCommands(entry.processGroup)
        // The longest word (usually the script path) identifies it even inside child commands.
        let words: [Substring] = entry.script.split(whereSeparator: { $0.isWhitespace })
        let signature = words.max { $0.count < $1.count }.map(String.init) ?? entry.script
        return commands.contains { $0.contains(entry.script) || $0.contains(signature) }
    }

    private func update(_ change: (inout [Entry]) -> Void) {
        lock.withLock {
            var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))) ?? []
            change(&entries)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        }
    }
}
