import Foundation

/// Built-in type OIDs are fixed across PostgreSQL versions and in Aurora DSQL.
public enum PostgresTypeNames {
    private static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4",
        25: "text", 26: "oid", 114: "json", 142: "xml", 650: "cidr", 700: "float4", 701: "float8",
        790: "money", 829: "macaddr", 869: "inet", 1000: "bool[]", 1005: "int2[]", 1007: "int4[]",
        1009: "text[]", 1015: "varchar[]", 1016: "int8[]", 1021: "float4[]", 1022: "float8[]",
        1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp",
        1184: "timestamptz", 1186: "interval", 1231: "numeric[]", 1266: "timetz", 1560: "bit",
        1562: "varbit", 1700: "numeric", 2950: "uuid", 2951: "uuid[]", 3802: "jsonb", 3807: "jsonb[]",
    ]

    public static func name(for oid: UInt32) -> String {
        names[oid] ?? "oid \(oid)"
    }
}
