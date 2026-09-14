import Foundation
import FindAnythingCore

@main struct SearchBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("Usage: swift run -c release FindYoshiBenchmark /path/to/Library.sqlite [--migrate] [--names-only]")
            return
        }
        let url = URL(fileURLWithPath: arguments[1])
        if arguments.contains("--migrate") { _ = try SearchEngine(databaseURL: url) }
        let reader = try SearchEngine(databaseURL: url, readOnly: true)
        for (query, mode) in [("report", SearchMode.names), ("README", .names), ("planning", .names), ("budget forecast", .hybrid), ("recover deleted text", .semantic)] {
            if arguments.contains("--names-only") && mode != .names { continue }
            for iteration in 0..<5 {
                var request = SearchRequest(query: query, mode: mode, limit: 12)
                request.namesOnly = arguments.contains("--names-only")
                let profile = try await reader.profile(request)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
                let output: [String: Any] = ["query": query, "mode": mode.rawValue, "iteration": iteration, "namesOnly": request.namesOnly, "profile": encoded]
                print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
                fflush(stdout)
            }
        }
    }
}
