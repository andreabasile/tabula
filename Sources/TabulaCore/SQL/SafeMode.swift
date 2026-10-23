import Foundation

public enum SafeMode: String, Codable, CaseIterable, Sendable {
    case silent
    case alertAll
    case alertWrites

    public var title: String {
        switch self {
        case .silent: "Silenziosa — invia le query senza avvisi"
        case .alertAll: "Avviso 1 — chiedi conferma prima di ogni query"
        case .alertWrites: "Avviso 2 — chiedi conferma tranne SELECT/EXPLAIN/SHOW"
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
    private static let readOnlyKeywords: Set<String> = ["select", "explain", "show", "values", "table"]

    public static func isReadOnly(_ statement: String) -> Bool {
        guard let keyword = firstKeyword(of: statement) else { return true }
        if keyword == "with" { return !containsWriteKeyword(statement) }
        return readOnlyKeywords.contains(keyword)
    }

    static func firstKeyword(of statement: String) -> String? {
        let code = StatementSplitter.strippingComments(statement)
        let trimmed = code.drop { $0.isWhitespace || $0 == "(" }
        let word = trimmed.prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }

    private static func containsWriteKeyword(_ statement: String) -> Bool {
        let words = StatementSplitter.strippingComments(statement)
            .lowercased()
            .split { !$0.isLetter }
        return words.contains { ["insert", "update", "delete", "merge"].contains($0) }
    }
}
