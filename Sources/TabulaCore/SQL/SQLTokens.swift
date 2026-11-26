import Foundation

/// A small lexer shared by the formatter, the limit check and autocompletion. Strings
/// (also `E'…'` and `$tag$…$tag$`), quoted names and comments come out as whole tokens,
/// so nothing reformats their content.
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
        func emit(from start: Int, _ kind: Token.Kind) {
            tokens.append(Token(text: String(characters[start..<index]), kind: kind))
        }
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let start = index
            if character.isWhitespace {
                index += 1
            } else if character == "-", next == "-" {
                while index < characters.count, !characters[index].isNewline { index += 1 }
                emit(from: start, .comment)
            } else if character == "/", next == "*" {
                index = end(of: ["*", "/"], in: characters, from: index + 2)
                emit(from: start, .comment)
            } else if character == "'" || character == "\"" {
                index = endOfQuoted(characters, from: index, backslashEscapes: false)
                emit(from: start, character == "'" ? .string : .quoted)
            } else if "eEbBxXnN".contains(character), next == "'" {
                // E'…', B'…', X'…', N'…': the prefix belongs to the string.
                index = endOfQuoted(characters, from: index + 1, backslashEscapes: character == "e" || character == "E")
                emit(from: start, .string)
            } else if character == "$", let tag = dollarTag(characters, at: index) {
                index = end(of: tag, in: characters, from: index + tag.count)
                emit(from: start, .string)
            } else if character.isLetter || character == "_" || character == "$" {
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "$" { index += 1 }
                emit(from: start, .word)
            } else if character.isNumber {
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                emit(from: start, .number)
            } else {
                let pair = next.map { String([character, $0]) } ?? ""
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

    /// Index just past the closing quote (a doubled quote stays inside), or the end of the text.
    private static func endOfQuoted(_ characters: [Character], from start: Int, backslashEscapes: Bool) -> Int {
        let quote = characters[start]
        var index = start + 1
        while index < characters.count {
            if backslashEscapes, characters[index] == "\\" {
                index += 2
                continue
            }
            if characters[index] == quote {
                if index + 1 < characters.count, characters[index + 1] == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return characters.count
    }

    /// Index just past the next `delimiter`, or the end of the text when it never comes.
    private static func end(of delimiter: [Character], in characters: [Character], from start: Int) -> Int {
        var index = start
        while index + delimiter.count <= characters.count {
            if characters[index..<(index + delimiter.count)].elementsEqual(delimiter) { return index + delimiter.count }
            index += 1
        }
        return characters.count
    }

    /// `$$` or `$tag$`; `$1` parameters are not tags.
    private static func dollarTag(_ characters: [Character], at start: Int) -> [Character]? {
        var index = start + 1
        while index < characters.count, characters[index] != "$" {
            let character = characters[index]
            guard character.isLetter || character == "_" || (index > start + 1 && character.isNumber) else { return nil }
            index += 1
        }
        guard index < characters.count else { return nil }
        return Array(characters[start...index])
    }
}
