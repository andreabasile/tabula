import Foundation

/// DSQL closes connections after 60 minutes; AWS's own connectors recycle them at 55.
public struct ConnectionLifetimePolicy: Equatable, Sendable {
    public static let dsql = ConnectionLifetimePolicy(maxAge: 55 * 60)
    public static let unlimited = ConnectionLifetimePolicy(maxAge: nil)

    public let maxAge: TimeInterval?

    public init(maxAge: TimeInterval?) {
        self.maxAge = maxAge
    }

    public func shouldRecycle(openedAt: Date, now: Date) -> Bool {
        guard let maxAge else { return false }
        return now.timeIntervalSince(openedAt) >= maxAge
    }
}
