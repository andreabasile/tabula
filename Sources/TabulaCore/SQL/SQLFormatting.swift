import Foundation

/// TablePlus's row limit popup: appended only to SELECTs that do not limit themselves.
public enum QueryLimit {
    public static let choices = [0, 100, 300, 500, 1000, 5000]

    public static func apply(_ limit: Int, to statement: String) -> String {
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasSuffix(";") ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        guard limit > 0,
              ["select", "with", "table", "values"].contains(StatementClassifier.firstKeyword(of: body) ?? ""),
              StatementClassifier.isReadOnly(body),
              !hasTopLevelLimit(body)
        else { return statement }
        return "\(body)\nLIMIT \(limit)"
    }

    private static func hasTopLevelLimit(_ sql: String) -> Bool {
        var depth = 0
        var previous = ""
        for token in SQLTokens.split(StatementSplitter.strippingComments(sql)) {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            let word = token.text.lowercased()
            if depth == 0, word == "limit" || (word == "fetch" && previous != "") { return true }
            previous = word
        }
        return false
    }
}

/// "Beautify" (⌘I): uppercase keywords, one clause per line, select lists and AND/OR indented.
/// Strings, quoted identifiers and comments are kept verbatim.
public enum SQLBeautifier {
    private static let clauseStarters: [[String]] = [
        ["select"], ["from"], ["where"], ["group", "by"], ["order", "by"], ["having"], ["limit"], ["offset"],
        ["left", "join"], ["right", "join"], ["inner", "join"], ["full", "join"], ["cross", "join"], ["join"],
        ["union", "all"], ["union"], ["except"], ["intersect"], ["values"], ["set"], ["returning"],
        ["insert", "into"], ["update"], ["delete", "from"], ["on", "conflict"],
    ]
    private static let keywords: Set<String> = [
        "select", "from", "where", "group", "by", "order", "having", "limit", "offset", "left", "right", "inner",
        "outer", "full", "cross", "join", "on", "using", "union", "all", "except", "intersect", "values", "set",
        "returning", "insert", "into", "update", "delete", "and", "or", "not", "in", "is", "null", "like", "ilike",
        "between", "exists", "as", "distinct", "case", "when", "then", "else", "end", "asc", "desc", "with",
        "true", "false", "conflict", "do", "nothing",
    ]

    public static func format(_ sql: String) -> String {
        StatementSplitter.split(sql).map { formatStatement($0.text) }.joined(separator: ";\n\n") + (sql.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(";") ? ";" : "")
    }

    private static func formatStatement(_ sql: String) -> String {
        let tokens = SQLTokens.split(sql)
        var output = ""
        var depth = 0
        var inSelectList = false
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let lowered = token.text.lowercased()
            if depth == 0, let clause = clause(at: index, in: tokens) {
                if !output.isEmpty { output = output.trimmingTrailingSpaces() + "\n" }
                output += clause.map { $0.uppercased() }.joined(separator: " ")
                inSelectList = clause == ["select"]
                output += inSelectList ? "\n  " : " "
                index += clause.count
                continue
            }
            switch token.text {
            case "(":
                depth += 1
                output += "("
            case ")":
                depth -= 1
                output = output.trimmingTrailingSpaces() + ") "
            case ",":
                output = output.trimmingTrailingSpaces() + (inSelectList && depth == 0 ? ",\n  " : ", ")
            case ".":
                output = output.trimmingTrailingSpaces() + "."
            default:
                if depth == 0, lowered == "and" || lowered == "or" {
                    output = output.trimmingTrailingSpaces() + "\n  " + lowered.uppercased() + " "
                } else {
                    let text = token.kind == .word && keywords.contains(lowered) ? lowered.uppercased() : token.text
                    output += text + (tokens.indices.contains(index + 1) && tokens[index + 1].text == "(" && token.kind == .word ? "" : " ")
                }
            }
            if output.hasSuffix(". ") { output.removeLast() }
            index += 1
        }
        return output.trimmingTrailingSpaces()
    }

    private static func clause(at index: Int, in tokens: [SQLTokens.Token]) -> [String]? {
        clauseStarters.first { words in
            guard index + words.count <= tokens.count else { return false }
            return words.enumerated().allSatisfy { tokens[index + $0.offset].text.lowercased() == $0.element }
        }
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var copy = self
        while copy.last == " " { copy.removeLast() }
        return copy
    }
}

/// A small lexer shared by the formatter and the limit check.
enum SQLTokens {
    struct Token {
        enum Kind { case word, string, quoted, number, symbol, comment }
        let text: String
        let kind: Kind
    }

    static func split(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(sql)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                let start = index
                while index < characters.count, characters[index] != "\n" { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), kind: .comment))
            } else if character == "'" || character == "\"" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == character {
                        if index + 1 < characters.count, characters[index + 1] == character { index += 2; continue }
                        index += 1
                        break
                    }
                    index += 1
                }
                tokens.append(Token(text: String(characters[start..<index]), kind: character == "'" ? .string : .quoted))
            } else if character.isLetter || character == "_" || character == "$" {
                let start = index
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "$" { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), kind: .word))
            } else if character.isNumber {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                tokens.append(Token(text: String(characters[start..<index]), kind: .number))
            } else {
                let pair = index + 1 < characters.count ? String([character, characters[index + 1]]) : ""
                if ["<>", "<=", ">=", "!=", "::", "||", "->"].contains(pair) {
                    tokens.append(Token(text: pair, kind: .symbol))
                    index += 2
                } else {
                    tokens.append(Token(text: String(character), kind: .symbol))
                    index += 1
                }
            }
        }
        return tokens
    }
}
