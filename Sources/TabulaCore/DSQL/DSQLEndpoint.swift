import Foundation

public enum DSQLEndpoint {
    /// Cluster endpoints look like `<cluster-id>.dsql.<region>.on.aws`.
    public static func region(from endpoint: String) -> String? {
        let labels = endpoint.lowercased().split(separator: ".").map(String.init)
        guard let dsqlIndex = labels.firstIndex(of: "dsql"),
              labels.indices.contains(dsqlIndex + 1)
        else { return nil }
        let region = labels[dsqlIndex + 1]
        return region.isEmpty ? nil : region
    }

    public static func isDSQLHost(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".on.aws") && region(from: host) != nil
    }
}
