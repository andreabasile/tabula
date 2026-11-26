import Foundation

public enum SafeMode: String, Codable, CaseIterable, Sendable {
    case silent
    case alertAll
    case alertWrites

    public var title: String {
        switch self {
        case .silent: String(localized: "Silent — send queries without warnings")
        case .alertAll: String(localized: "Warning 1 — confirm before every query")
        case .alertWrites: String(localized: "Warning 2 — confirm except SELECT/EXPLAIN/SHOW")
        }
    }

    public func requiresConfirmation(for statements: [String]) -> Bool {
        switch self {
        case .silent: false
        case .alertAll: !statements.isEmpty
        case .alertWrites: statements.contains { !StatementClassifier.isReadOnly($0) }
        }
    }
}

public enum StatementClassifier {
    private static let readKeywords: Set<String> = ["select", "values", "table", "with"]
    private static let writeVerbs: Set<String> = ["insert", "update", "delete", "merge"]

    public static func isReadOnly(_ statement: String) -> Bool {
        // Tokens, not text: names like insert_date and words in strings or comments are not keywords.
        let tokens = SQLTokens.split(statement).filter { $0.kind != .comment }
        guard let start = tokens.firstIndex(where: { $0.text != "(" }), tokens[start].kind == .word else { return true }
        switch tokens[start].text.lowercased() {
        case "show": return true
        case "explain": return explainIsReadOnly(Array(tokens[(start + 1)...]))
        default: return isRead(tokens)
        }
    }

    /// SELECT, VALUES, TABLE or WITH with no write verb where a statement starts (a WITH body after
    /// `(`, its main statement after `)`), and no INTO: SELECT … INTO creates a table.
    /// FOR UPDATE and columns named update follow other words, so they stay reads.
    private static func isRead(_ tokens: [SQLTokens.Token]) -> Bool {
        guard let first = tokens.first(where: { $0.text != "(" }), readKeywords.contains(first.text.lowercased()) else { return false }
        for (index, token) in tokens.enumerated() where token.kind == .word {
            let word = token.text.lowercased()
            if word == "into" { return false }
            if writeVerbs.contains(word), index > 0, ["(", ")"].contains(tokens[index - 1].text) { return false }
        }
        return true
    }

    /// Plain EXPLAIN only plans; EXPLAIN ANALYZE runs the statement it explains, so that one decides.
    private static func explainIsReadOnly(_ tokens: [SQLTokens.Token]) -> Bool {
        var rest = tokens[...]
        var analyzes = false
        if rest.first?.text == "(" {
            guard let close = rest.firstIndex(where: { $0.text == ")" }) else { return false }
            analyzes = rest[..<close].contains { ["analyze", "analyse"].contains($0.text.lowercased()) }
            rest = rest[(close + 1)...]
        } else {
            while let word = rest.first?.text.lowercased(), ["analyze", "analyse", "verbose"].contains(word) {
                analyzes = analyzes || word != "verbose"
                rest = rest.dropFirst()
            }
        }
        return !analyzes || isRead(Array(rest))
    }

    public static func firstKeyword(of statement: String) -> String? {
        let code = StatementSplitter.strippingComments(statement)
        let trimmed = code.drop { $0.isWhitespace || $0 == "(" }
        let word = trimmed.prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }
}
