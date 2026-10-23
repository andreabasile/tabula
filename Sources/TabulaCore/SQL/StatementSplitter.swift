import Foundation

public struct SQLStatement: Equatable, Sendable {
    public let text: String
    /// UTF-16 offsets into the original script, so they line up with NSTextView ranges.
    public let range: Range<Int>
}

/// Splits a script on `;` while respecting quotes, dollar quotes and comments.
public enum StatementSplitter {
    public static func split(_ script: String) -> [SQLStatement] {
        var scanner = Scanner(script)
        var statements: [SQLStatement] = []
        var start = 0
        while let character = scanner.peek() {
            if scanner.skipQuotedOrComment() { continue }
            scanner.advance()
            if character == 0x3B {
                append(script, from: start, to: scanner.offset - 1, into: &statements)
                start = scanner.offset
            }
        }
        append(script, from: start, to: scanner.offset, into: &statements)
        return statements
    }

    /// The statement under the cursor, as TablePlus's "Run current" does.
    public static func statement(in script: String, at cursor: Int) -> SQLStatement? {
        let statements = split(script)
        return statements.first { cursor >= $0.range.lowerBound && cursor <= $0.range.upperBound + 1 }
            ?? statements.last { $0.range.upperBound < cursor }
    }

    public static func strippingComments(_ sql: String) -> String {
        var scanner = Scanner(sql)
        var output: [UTF16.CodeUnit] = []
        while let character = scanner.peek() {
            let before = scanner.offset
            if scanner.skipComment() {
                output.append(UTF16.CodeUnit(UInt8(ascii: " ")))
                continue
            }
            if scanner.skipQuoted() {
                output.append(contentsOf: scanner.units[before..<scanner.offset])
                continue
            }
            output.append(character)
            scanner.advance()
        }
        return String(decoding: output, as: UTF16.self)
    }

    private static func append(_ script: String, from start: Int, to end: Int, into statements: inout [SQLStatement]) {
        let units = Array(script.utf16)
        guard start < end else { return }
        let raw = String(decoding: units[start..<end], as: UTF16.self)
        let leading = raw.utf16.prefix { isWhitespace($0) }.count
        let trailing = raw.utf16.reversed().prefix { isWhitespace($0) }.count
        guard leading < raw.utf16.count else { return }
        let range = (start + leading)..<(end - trailing)
        let text = String(decoding: units[range], as: UTF16.self)
        guard !strippingComments(text).allSatisfy(\.isWhitespace) else { return }
        statements.append(SQLStatement(text: text, range: range))
    }

    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

private struct Scanner {
    let units: [UTF16.CodeUnit]
    var offset = 0

    init(_ text: String) {
        units = Array(text.utf16)
    }

    func peek(_ ahead: Int = 0) -> UTF16.CodeUnit? {
        let index = offset + ahead
        return index < units.count ? units[index] : nil
    }

    mutating func advance(_ count: Int = 1) {
        offset = min(offset + count, units.count)
    }

    mutating func skipQuotedOrComment() -> Bool {
        skipComment() || skipQuoted()
    }

    mutating func skipComment() -> Bool {
        if peek() == ascii("-"), peek(1) == ascii("-") {
            while let unit = peek(), unit != ascii("\n") { advance() }
            return true
        }
        if peek() == ascii("/"), peek(1) == ascii("*") {
            advance(2)
            while peek() != nil, !(peek() == ascii("*") && peek(1) == ascii("/")) { advance() }
            advance(2)
            return true
        }
        return false
    }

    mutating func skipQuoted() -> Bool {
        guard let unit = peek() else { return false }
        if unit == ascii("'") || unit == ascii("\"") {
            skipDelimited(by: unit)
            return true
        }
        if unit == ascii("$"), let tag = dollarTag() {
            advance(tag.count)
            while peek() != nil, !matches(tag) { advance() }
            advance(tag.count)
            return true
        }
        return false
    }

    private mutating func skipDelimited(by quote: UTF16.CodeUnit) {
        advance()
        while let unit = peek() {
            advance()
            guard unit == quote else { continue }
            if peek() == quote { advance() } else { return }
        }
    }

    /// `$$` or `$tag$`, where tag is an identifier (so `$1` parameters are not tags).
    private func dollarTag() -> [UTF16.CodeUnit]? {
        var length = 1
        while let unit = peek(length), unit != ascii("$") {
            let isIdentifier = (unit >= ascii("a") && unit <= ascii("z")) || (unit >= ascii("A") && unit <= ascii("Z"))
                || unit == ascii("_") || (length > 1 && unit >= ascii("0") && unit <= ascii("9"))
            guard isIdentifier else { return nil }
            length += 1
        }
        guard peek(length) == ascii("$") else { return nil }
        return Array(units[offset...(offset + length)])
    }

    private func matches(_ tag: [UTF16.CodeUnit]) -> Bool {
        guard offset + tag.count <= units.count else { return false }
        return Array(units[offset..<(offset + tag.count)]) == tag
    }

    private func ascii(_ character: Unicode.Scalar) -> UTF16.CodeUnit {
        UTF16.CodeUnit(character.value)
    }
}
