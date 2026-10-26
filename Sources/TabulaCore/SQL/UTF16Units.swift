import Foundation

extension String {
    /// The UTF-16 code units in one bulk copy. Text coming from NSTextView is NSString-backed,
    /// where `Array(utf16)` walks it unit by unit and costs tens of ms on a long script.
    public var utf16Units: [UTF16.CodeUnit] {
        let string = self as NSString
        var units = [UTF16.CodeUnit](repeating: 0, count: string.length)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { string.getCharacters(base, range: NSRange(location: 0, length: string.length)) }
        }
        return units
    }
}
