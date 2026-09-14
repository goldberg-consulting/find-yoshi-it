import Foundation

@main struct BenchmarkApple {
    static func main() throws {
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let cases = input["cases"] as! [[String: String]]
        let documents = cases.map { $0["text"]! } + (input["distractors"] as! [String])
        let encoder = SemanticEncoder()
        guard encoder.isAvailable else { throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Apple sentence model unavailable"]) }
        let start = Date()
        let docVectors = documents.map { encoder.encode($0)! }
        let queryVectors = cases.map { encoder.encode($0["query"]!)! }
        let output: [String: Any] = ["model": encoder.modelID, "documents": docVectors, "queries": queryVectors,
            "queryBuckets": queryVectors.map(SemanticEncoder.queryBuckets), "documentBuckets": docVectors.map(SemanticEncoder.buckets),
            "embeddingSeconds": Date().timeIntervalSince(start)]
        try JSONSerialization.data(withJSONObject: output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
