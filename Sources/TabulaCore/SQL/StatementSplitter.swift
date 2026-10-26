import Foundation

public struct SQLStatement: Equatable, Sendable {
    public let text: String
    /// UTF-16 offsets into the original script, so they line up with NSTextView ranges.
    public let range: Range<Int>
}

/// Splits a script on `;` while respecting quotes, dollar quotes and comments.
public enum StatementSplitter {
    public static func split(_ script: String) -> [SQLStatement] {
        let units = script.utf16Units
        return segments(units).compactMap { statement(units, in: $0) }
    }

    /// The statement under the cursor, as TablePlus's "Run current" does.
    /// Only the segments next to the cursor are turned into strings, so this stays cheap on long scripts.
    public static func statement(in script: String, at cursor: Int) -> SQLStatement? {
        let units = script.utf16Units
        let segments = segments(units)
        guard let index = segments.lastIndex(where: { $0.lowerBound <= cursor }) else {
            return segments.lazy.compactMap { statement(units, in: $0) }.first { cursor >= $0.range.lowerBound }
        }
        // Right after a `;` the cursor still belongs to the statement it closes.
        for candidate in [index - 1, index] where candidate >= 0 {
            if let found = statement(units, in: segments[candidate]),
               cursor >= found.range.lowerBound, cursor <= found.range.upperBound + 1 {
                return found
            }
        }
        for candidate in stride(from: index, through: 0, by: -1) {
            if let found = statement(units, in: segments[candidate]), found.range.upperBound < cursor { return found }
        }
        return nil
    }

    /// Raw ranges between top-level `;`, without building any string.
    private static func segments(_ units: [UTF16.CodeUnit]) -> [Range<Int>] {
        var scanner = Scanner(units)
        var segments: [Range<Int>] = []
        var start = 0
        while let character = scanner.peek() {
            if scanner.skipQuotedOrComment() { continue }
            scanner.advance()
            if character == 0x3B {
                segments.append(start..<(scanner.offset - 1))
                start = scanner.offset
            }
        }
        segments.append(start..<scanner.offset)
        return segments
    }

    /// Where the comment or quoted text spanning `offset` begins, or `offset` itself in plain SQL.
    /// Lets the editor color a window of a long script as if it had read it from the top.
    public static func regionStart(containing offset: Int, in script: String) -> Int {
        var scanner = Scanner(script)
        while scanner.offset < offset, scanner.peek() != nil {
            let before = scanner.offset
            if scanner.skipQuotedOrComment() {
                if scanner.offset > offset { return before }
                continue
            }
            scanner.advance()
        }
        return offset
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

    private static func statement(_ units: [UTF16.CodeUnit], in segment: Range<Int>) -> SQLStatement? {
        var start = segment.lowerBound
        var end = segment.upperBound
        while start < end, isWhitespace(units[start]) { start += 1 }
        while end > start, isWhitespace(units[end - 1]) { end -= 1 }
        guard start < end else { return nil }
        let text = String(decoding: units[start..<end], as: UTF16.self)
        guard !strippingComments(text).allSatisfy(\.isWhitespace) else { return nil }
        return SQLStatement(text: text, range: start..<end)
    }

    private static func isWhitespace(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

private struct Scanner {
    let units: [UTF16.CodeUnit]
    var offset = 0

    init(_ text: String) {
        units = text.utf16Units
    }

    init(_ units: [UTF16.CodeUnit]) {
        self.units = units
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
