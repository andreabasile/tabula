import AppKit
import TabulaCore

/// At launch, asks GitHub for the latest release and shows a one-time notice when it is newer.
@MainActor
enum UpdateCheck {
    private static let notifiedKey = "lastNotifiedUpdateVersion"
    private static let upgradeCommand = "brew upgrade --cask tabula"

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: URL
    }

    static func start() {
        // `swift run` builds are not bundles and have no version to compare.
        guard let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        Task {
            // Leave the launch alone and let the first window come up before any alert.
            try? await Task.sleep(for: .seconds(3))
            guard let release = await latestRelease() else { return }
            let latest = String(release.tagName.trimmingPrefix("v"))
            guard ReleaseVersion.isNewer(latest, than: installed),
                  UserDefaults.standard.string(forKey: notifiedKey) != latest else { return }
            notify(latest: latest, installed: installed, notes: release.htmlUrl)
        }
    }

    /// Any failure (offline, rate limit, unexpected JSON) just means no notice this time.
    private static func latestRelease() async -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/andreabasile/tabula/releases/latest")!, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tabula", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Release.self, from: data)
    }

    private static func notify(latest: String, installed: String, notes: URL) {
        // Recorded up front: whatever the answer (or a quit), the same version never nags twice.
        UserDefaults.standard.set(latest, forKey: notifiedKey)
        let alert = NSAlert()
        alert.messageText = String(localized: "Tabula \(latest) is available")
        alert.informativeText = String(localized: "You have version \(installed). You can update it with Homebrew:\nbrew upgrade --cask tabula")
        alert.addButton(withTitle: String(localized: "Copy Update Command"))
        alert.addButton(withTitle: String(localized: "Release Notes"))
        alert.addButton(withTitle: String(localized: "Later")).keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: Pasteboard.copy(upgradeCommand)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(notes)
        default: break
        }
    }
}
