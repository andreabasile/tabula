/// Release versions such as "v1.10.0" (GitHub tags) or "1.10.0" (CFBundleShortVersionString).
public enum ReleaseVersion {
    /// True when `candidate` is strictly higher than `current`. Components are compared as numbers,
    /// a missing one counts as 0, and a version with a non-numeric component is never newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let newPart = index < new.count ? new[index] : 0
            let oldPart = index < old.count ? old[index] : 0
            if newPart != oldPart { return newPart > oldPart }
        }
        return false
    }

    private static func components(_ version: String) -> [UInt]? {
        let parts = version.trimmingPrefix("v").split(separator: ".", omittingEmptySubsequences: false).map { UInt($0) }
        return parts.contains(nil) ? nil : parts.compactMap { $0 }
    }
}
