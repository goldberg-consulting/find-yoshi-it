import Foundation

struct EmbeddingInput: Sendable {
    let id: Int64
    let text: String
}

struct EncodedPassage: Sendable {
    let id: Int64
    let modelID: String
    let data: Data
}

/// Two serial workers own independent NaturalLanguage models. The database actor
/// stays available while they encode, and the pool cannot grow with library size.
struct EmbeddingWorkers: Sendable {
    static let shared = EmbeddingWorkers()
    private let first = EmbeddingWorker()
    private let second = EmbeddingWorker()

    func encode(_ inputs: [EmbeddingInput]) async throws -> [EncodedPassage] {
        let split = (inputs.count + 1) / 2
        async let left = first.encode(Array(inputs.prefix(split)))
        async let right = second.encode(Array(inputs.dropFirst(split)))
        return try await left + right
    }
}

private actor EmbeddingWorker {
    private var encoder: SemanticEncoder?

    func encode(_ inputs: [EmbeddingInput]) throws -> [EncodedPassage] {
        guard !inputs.isEmpty else { return [] }
        try Task.checkCancellation()
        if encoder == nil { encoder = SemanticEncoder() }
        guard let encoder else { return [] }
        return try inputs.compactMap { input in
            try Task.checkCancellation()
            guard let vector = encoder.encode(input.text) else { return nil }
            return EncodedPassage(id: input.id, modelID: encoder.modelID, data: SemanticEncoder.pack(vector))
        }
    }
}
