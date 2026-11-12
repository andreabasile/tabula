import Foundation

/// Client-side ordering of a query result, used when clicking a column header: the query
/// is not re-run, so the order follows PostgreSQL's defaults (NULLS LAST ascending,
/// NULLS FIRST descending) and numbers compare as numbers.
public enum ResultSorting {
    private static let numericTypes: Set<String> = ["int2", "int4", "int8", "oid", "float4", "float8", "numeric", "money"]

    /// Reorders `indexes` by `value(index)`; ties keep their original relative order.
    public static func sort(
        _ indexes: [Int],
        typeName: String,
        ascending: Bool,
        value: (Int) -> CellValue
    ) -> [Int] {
        let numeric = numericTypes.contains(typeName)
        let keyed = indexes.enumerated().map { position, index in
            (position: position, index: index, key: Key(value(index), numeric: numeric))
        }
        return keyed.sorted { lhs, rhs in
            switch Key.compare(lhs.key, rhs.key) {
            case .orderedSame: lhs.position < rhs.position
            case .orderedAscending: ascending
            case .orderedDescending: !ascending
            }
        }.map(\.index)
    }

    private enum Key {
        case number(Double)
        case text(String)
        case null

        init(_ value: CellValue, numeric: Bool) {
            guard let text = value.textValue else {
                self = .null
                return
            }
            if numeric, let number = Double(text.filter { $0 != "$" && $0 != "," }) {
                self = .number(number)
            } else {
                self = .text(text)
            }
        }

        /// NULL sorts as the largest value, as in PostgreSQL.
        static func compare(_ lhs: Key, _ rhs: Key) -> ComparisonResult {
            switch (lhs, rhs) {
            case (.null, .null): .orderedSame
            case (.null, _): .orderedDescending
            case (_, .null): .orderedAscending
            case let (.number(a), .number(b)): a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
            case (.number, .text): .orderedAscending
            case (.text, .number): .orderedDescending
            case let (.text(a), .text(b)): a.localizedStandardCompare(b)
            }
        }
    }
}
