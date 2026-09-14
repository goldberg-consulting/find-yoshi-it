import Foundation

public enum FileSearchCategory: String, Sendable {
    case all, documents, other
}

public enum SearchPresentation {
    public static let documentExtensions: Set<String> = [
        "md", "markdown", "mdown", "txt", "text", "rtf", "rtfd", "pdf",
        "doc", "docx", "odt", "pages", "ppt", "pptx", "odp", "key", "keynote",
        "xls", "xlsx", "xlsm", "ods", "numbers", "csv", "tsv", "epub"
    ]
    public static let dependencyDirectories = [".venv", "venv", "node_modules", ".node_modules", ".node"]

    public static func isExcluded(_ relativePath: String, patterns: [String]) -> Bool {
        LocalFiles.excluded(relativePath, patterns: patterns)
    }

    public static func isDocument(extension value: String) -> Bool { documentExtensions.contains(value.lowercased()) }

    public static func isDependencyPath(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        return parts.contains(where: dependencyDirectories.contains) || (path as NSString).pathExtension.lowercased() == "node"
    }

    static func explicitlyRequests(_ component: String, query: String) -> Bool {
        let tokens = query.lowercased().split { $0.isWhitespace || $0 == "/" || $0 == "\\" || $0 == "\"" || $0 == "'" }
        return tokens.contains(Substring(component)) || (component == ".node" && tokens.contains { $0.hasSuffix(".node") })
    }
}
