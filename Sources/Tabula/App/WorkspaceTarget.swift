import Foundation

/// The value a workspace window is opened with. The unique `id` lets the same
/// connection be opened twice, and `inNewWindow` skips joining the tab group.
struct WorkspaceTarget: Codable, Hashable {
    var id = UUID()
    let connectionID: UUID
    var inNewWindow = false
}
