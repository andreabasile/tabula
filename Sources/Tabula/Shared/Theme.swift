import AppKit
import SwiftUI

/// TablePlus keeps every surface white (or near-black in dark mode) and leaves
/// colour to selection and tags; these are the few tones the UI uses.
enum Theme {
    static let surface = Color(nsColor: .textBackgroundColor)
    static let hover = Color.primary.opacity(0.045)
    static let border = Color(nsColor: .separatorColor)
    static let selection = Color.accentColor.opacity(0.14)

    static let surfaceNS = NSColor.textBackgroundColor
}
