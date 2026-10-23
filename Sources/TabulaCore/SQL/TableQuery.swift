import Foundation

public enum FilterOperator: String, CaseIterable, Codable, Sendable {
    case equals = "="
    case notEquals = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    case contains = "contains"
    case notContains = "not contains"
    case hasPrefix = "has prefix"
    case hasSuffix = "has suffix"
    case isNull = "is null"
    case isNotNull = "is not null"
    case inList = "in"

    public var needsValue: Bool { self != .isNull && self != .isNotNull }
}

public struct ColumnFilter: Equatable, Codable, Sendable {
    /// nil means "any column", matched with OR across all of them.
    public var column: String?
    public var op: FilterOperator
    public var value: String

    public init(column: String?, op: FilterOperator, value: String) {
        self.column = column
        self.op = op
        self.value = value
    }

    public func condition(allColumns: [String]) -> String? {
        if op.needsValue, value.isEmpty { return nil }
        guard let column else {
            let parts = allColumns.compactMap { ColumnFilter(column: $0, op: op, value: value).condition(allColumns: []) }
            return parts.isEmpty ? nil : "(" + parts.joined(separator: " OR ") + ")"
        }
        return condition(for: SQLRendering.identifier(column))
    }

    private func condition(for column: String) -> String {
        let text = "\(column)::text"
        switch op {
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .contains: return "\(text) ILIKE \(likePattern("%", value, "%"))"
        case .notContains: return "\(text) NOT ILIKE \(likePattern("%", value, "%"))"
        case .hasPrefix: return "\(text) ILIKE \(likePattern("", value, "%"))"
        case .hasSuffix: return "\(text) ILIKE \(likePattern("%", value, ""))"
        case .inList:
            let items = value.split(separator: ",").map { SQLRendering.literal(.text($0.trimmingCharacters(in: .whitespaces))) }
            return "\(text) IN (\(items.joined(separator: ", ")))"
        default:
            return "\(column) \(op.rawValue) \(SQLRendering.literal(.text(value)))"
        }
    }

    private func likePattern(_ prefix: String, _ value: String, _ suffix: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return SQLRendering.literal(.text(prefix + escaped + suffix))
    }
}

public struct SortOrder: Equatable, Codable, Sendable {
    public var column: String
    public var ascending: Bool

    public init(column: String, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct TableQuery: Equatable, Sendable {
    public static let defaultPageSize = 300

    public var table: TableReference
    public var filters: [ColumnFilter]
    public var sort: SortOrder?
    public var page: Int
    public var pageSize: Int

    public init(table: TableReference, filters: [ColumnFilter] = [], sort: SortOrder? = nil, page: Int = 0, pageSize: Int = TableQuery.defaultPageSize) {
        self.table = table
        self.filters = filters
        self.sort = sort
        self.page = page
        self.pageSize = pageSize
    }

    public func selectSQL(columns: [String]) -> String {
        var sql = "SELECT * FROM \(table.qualifiedName)" + whereSQL(columns: columns)
        if let sort {
            sql += " ORDER BY \(SQLRendering.identifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
        }
        sql += " LIMIT \(pageSize) OFFSET \(page * pageSize)"
        return sql
    }

    public func countSQL(columns: [String]) -> String {
        "SELECT count(*) FROM \(table.qualifiedName)" + whereSQL(columns: columns)
    }

    private func whereSQL(columns: [String]) -> String {
        let conditions = filters.compactMap { $0.condition(allColumns: columns) }
        return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }
}
