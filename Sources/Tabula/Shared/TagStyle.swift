import SwiftUI
import TabulaCore

extension ConnectionTag {
    /// Same palette TablePlus uses for its environment labels.
    var color: Color {
        switch self {
        case .local: Color(red: 0.56, green: 0.56, blue: 0.58)
        case .testing: Color(red: 0.35, green: 0.70, blue: 0.40)
        case .development: Color(red: 0.25, green: 0.55, blue: 0.95)
        case .staging: Color(red: 0.95, green: 0.62, blue: 0.20)
        case .production: Color(red: 0.90, green: 0.27, blue: 0.27)
        }
    }

    var title: String { rawValue }
}

struct TagBadge: View {
    let tag: ConnectionTag

    var body: some View {
        Text(tag.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(tag.color, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct DriverIcon: View {
    let kind: ConnectionKind
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(isDSQL ? Color(red: 0.55, green: 0.32, blue: 0.85) : Color(red: 0.20, green: 0.40, blue: 0.62))
            Text(isDSQL ? "DS" : "Pg")
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var isDSQL: Bool {
        if case .dsql = kind { return true }
        return false
    }
}
