import Foundation
import NaturalLanguage

/// Encodes English passages with the Mac's available sentence model, without network requests.
///
/// Confine an instance to its owning actor. A missing system model disables encoding and leaves
/// lexical search available. This initial encoder supports English; it is not a multilingual
/// retrieval model. Persist `modelID` with every vector and rebuild when the identifier changes.
///
/// The LSH helpers generate SQLite lookup keys for bounded approximate candidate retrieval.
/// They do not scan a corpus or guarantee nearest-neighbor recall. Candidate limits, correlated
/// embeddings, and quantization affect recall and must be measured on the actual document corpus.
public final class SemanticEncoder {
    private let embedding: NLEmbedding?
    private static let maximumDimensions = 4_096
    private static let tableCount = 10
    private static let bitsPerTable = 12
    private static let probeBitCount = 8
    private static let magic: [UInt8] = [0x46, 0x41, 0x56, 0x31] // FAV1

    /// Whether a compatible English sentence model is available on this Mac.
    public var isAvailable: Bool { embedding != nil }

    /// Identifies the model, OS, quantization format, and bucket algorithm for safe rebuilds.
    public let modelID: String

    /// Loads an available local English model without requesting a download.
    public init() {
        let candidate = NLEmbedding.sentenceEmbedding(for: .english)
        if let candidate, candidate.dimension > 0, candidate.dimension <= Self.maximumDimensions {
            embedding = candidate
        } else {
            embedding = nil
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let revision = embedding.map { String($0.revision) } ?? "unavailable"
        let dimension = embedding.map { String($0.dimension) } ?? "0"
        modelID = "apple-nl-sentence-en-r\(revision)-d\(dimension)-\(os)-unit-i8-v1-lsh10x12-p8r3-v2"
    }

    /// Returns a unit vector, or nil for unavailable models, empty input, or invalid output.
    /// Input is bounded to 4,096 characters; callers should submit location-aware passages.
    public func encode(_ text: String) -> [Float]? {
        guard let embedding else { return nil }
        let input = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_096))
        guard !input.isEmpty, let vector = embedding.vector(for: input) else { return nil }
        return Self.normalized(vector.map(Float.init))
    }

    /// Stores a unit vector as a versioned header and one signed byte per dimension.
    /// Uses a per-vector scale; invalid, zero, or oversized vectors return empty data.
    public static func pack(_ vector: [Float]) -> Data {
        guard let unit = normalized(vector), let maximum = unit.map({ abs($0) }).max() else {
            return Data()
        }
        let scale = maximum / 127
        guard scale > 0, scale.isFinite else { return Data() }
        var bytes = magic
        appendLittleEndian(UInt32(unit.count), to: &bytes)
        appendLittleEndian(scale.bitPattern, to: &bytes)
        bytes.reserveCapacity(12 + unit.count)
        for value in unit {
            let quantized = Int8(max(-127, min(127, (value / scale).rounded())))
            bytes.append(UInt8(bitPattern: quantized))
        }
        return Data(bytes)
    }

    /// Decodes and normalizes the versioned signed-byte representation, or returns an empty array.
    /// Rejects malformed headers, nonfinite scales, invalid dimensions, and reserved byte values.
    public static func unpack(_ data: Data) -> [Float] {
        guard data.count >= 13, data.count <= 12 + maximumDimensions else { return [] }
        let bytes = [UInt8](data)
        guard Array(bytes.prefix(4)) == magic else { return [] }
        let dimension = Int(readLittleEndian(bytes, at: 4))
        let scale = Float(bitPattern: readLittleEndian(bytes, at: 8))
        guard dimension > 0, dimension <= maximumDimensions, bytes.count == 12 + dimension,
              scale.isFinite, scale > 0, scale <= 1,
              !bytes.dropFirst(12).contains(0x80) else { return [] }
        let decoded = bytes.dropFirst(12).map { Float(Int8(bitPattern: $0)) * scale }
        return normalized(decoded) ?? []
    }

    /// Returns cosine similarity in [-1, 1], or zero for invalid or mismatched vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, let left = normalized(a), let right = normalized(b) else { return 0 }
        let dot = zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return max(-1, min(1, dot))
    }

    /// Returns ten deterministic table-prefixed keys for indexing one valid vector.
    /// Store keys with the versioned passage ID and a B-tree index on the bucket column.
    public static func buckets(for vector: [Float]) -> [Int64] {
        signatures(for: vector).enumerated().map { table, signature in
            key(table: table, signature: signature.bits)
        }
    }

    /// Returns at most 930 lookup keys, probing nearby partitions without reading all vectors.
    /// Each table probes its primary key and all one-, two-, and three-bit combinations among
    /// the eight lowest-margin bits. Broad probes improve paraphrase recall but increase posting
    /// reads; SQL grouping and candidate recall require benchmarking at production scale.
    /// Apply source/access filters and a hard candidate limit in SQL before decoding vectors.
    public static func queryBuckets(for vector: [Float]) -> [Int64] {
        let signatures = signatures(for: vector)
        var result: [Int64] = []
        result.reserveCapacity(tableCount * 93)
        // Place all primary buckets first so sequential bounded lookups visit every table.
        for (table, signature) in signatures.enumerated() {
            result.append(key(table: table, signature: signature.bits))
        }
        for (table, signature) in signatures.enumerated() {
            let nearBits = signature.margins.enumerated().sorted {
                $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element
            }.prefix(probeBitCount).map(\.offset)
            for bit in nearBits {
                result.append(key(table: table, signature: signature.bits ^ (1 << bit)))
            }
            for first in nearBits.indices {
                for second in nearBits.indices where second > first {
                    result.append(key(table: table, signature: signature.bits ^
                        (1 << nearBits[first]) ^ (1 << nearBits[second])))
                    for third in nearBits.indices where third > second {
                        result.append(key(table: table, signature: signature.bits ^
                            (1 << nearBits[first]) ^ (1 << nearBits[second]) ^ (1 << nearBits[third])))
                    }
                }
            }
        }
        return result
    }

    private struct Signature {
        var bits: Int64
        var margins: [Double]
    }

    private static func key(table: Int, signature: Int64) -> Int64 {
        (Int64(table) << bitsPerTable) | signature
    }

    private static func signatures(for vector: [Float]) -> [Signature] {
        guard let unit = normalized(vector) else { return [] }
        var result: [Signature] = []
        result.reserveCapacity(tableCount)
        for table in 0..<tableCount {
            var bits: Int64 = 0
            var margins: [Double] = []
            margins.reserveCapacity(bitsPerTable)
            for bit in 0..<bitsPerTable {
                let offset = (table * bitsPerTable + bit) * maximumDimensions
                var dot = 0.0
                var planeSquaredLength = 0.0
                for dimension in unit.indices {
                    let weight = Double(hyperplanes[offset + dimension])
                    dot += Double(unit[dimension]) * weight
                    planeSquaredLength += weight * weight
                }
                if dot >= 0 { bits |= 1 << bit }
                margins.append(planeSquaredLength > 0 ? abs(dot) / sqrt(planeSquaredLength) : .infinity)
            }
            result.append(Signature(bits: bits, margins: margins))
        }
        return result
    }

    // A fixed SplitMix64 stream yields integer hyperplanes with approximately normal weights
    // (centered Binomial(64, 0.5)). Integer coefficients avoid platform-dependent RNG or libm
    // generation. A single immutable, lazily initialized 480 KiB matrix bounds shared memory.
    // Changing this seed, matrix layout, or dimensions requires a new LSH version in modelID.
    private static let hyperplanes: [Int8] = {
        var state: UInt64 = 0x46494E44414E5954
        return (0..<(tableCount * bitsPerTable * maximumDimensions)).map { _ in
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            return Int8(value.nonzeroBitCount - 32)
        }
    }()

    private static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.count <= maximumDimensions,
              vector.allSatisfy(\.isFinite), let maximum = vector.map({ abs($0) }).max(),
              maximum > 0 else { return nil }
        // Scale first so very large or very small finite input cannot overflow/underflow the norm.
        let scaled = vector.map { Double($0) / Double(maximum) }
        let length = sqrt(scaled.reduce(0) { $0 + $1 * $1 })
        guard length.isFinite, length > 0 else { return nil }
        return scaled.map { Float($0 / length) }
    }

    private static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static func readLittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { result, index in
            result | (UInt32(bytes[offset + index]) << (index * 8))
        }
    }
}
