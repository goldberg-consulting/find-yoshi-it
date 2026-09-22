import Foundation
import FindAnythingCore

/// Same complete filename, including extension; grouping does not imply identical contents.
struct ResultGroup: Identifiable {
    let id: String
    var results: [SearchResult]
    var first: SearchResult { results[0] }

    static func make(_ results: [SearchResult]) -> [ResultGroup] {
        var groups: [ResultGroup] = []
        var positions: [String: Int] = [:]
        var paths = Set<String>()
        for result in results where paths.insert(result.path).inserted {
            let key = result.filename.precomposedStringWithCanonicalMapping.lowercased()
            if let position = positions[key] { groups[position].results.append(result) }
            else {
                positions[key] = groups.count
                groups.append(ResultGroup(id: key, results: [result]))
            }
        }
        return groups
    }
}
