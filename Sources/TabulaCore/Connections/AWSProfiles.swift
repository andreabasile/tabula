import Foundation

/// Profile names from ~/.aws/config and ~/.aws/credentials, for the profile picker.
public enum AWSProfiles {
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let config = (try? String(contentsOf: home.appendingPathComponent(".aws/config"), encoding: .utf8)) ?? ""
        let credentials = (try? String(contentsOf: home.appendingPathComponent(".aws/credentials"), encoding: .utf8)) ?? ""
        return Array(Set(parse(config: config) + parse(credentials: credentials))).sorted()
    }

    static func parse(config: String) -> [String] {
        sections(in: config).compactMap { section in
            if section == "default" { return section }
            guard section.hasPrefix("profile ") else { return nil }
            return section.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
        }
    }

    static func parse(credentials: String) -> [String] {
        sections(in: credentials)
    }

    private static func sections(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
    }
}
