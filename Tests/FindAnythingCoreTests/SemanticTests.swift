import Foundation
import XCTest
@testable import FindAnythingCore

final class SemanticTests: XCTestCase {
    func testParallelEmbeddingMatchesSerialEncodingAndSkipsLegacyBuckets() async throws {
        let encoder = SemanticEncoder()
        guard encoder.isAvailable else { throw XCTSkip("Local sentence model unavailable") }
        let inputs = (0..<64).map { EmbeddingInput(id: Int64($0), text: "Document \($0) describes reliable incremental indexing and network storage.") }
        // Warm both paths before measuring this synthetic batch.
        _ = encoder.encode(inputs[0].text)
        _ = try await EmbeddingWorkers.shared.encode(inputs)
        let serialStart = ContinuousClock.now
        let expected = inputs.map { SemanticEncoder.pack(encoder.encode($0.text)!) }
        let serialTime = serialStart.duration(to: .now)
        let parallelStart = ContinuousClock.now
        let actual = try await EmbeddingWorkers.shared.encode(inputs)
        let parallelTime = parallelStart.duration(to: .now)
        XCTAssertEqual(actual.map(\.id), inputs.map(\.id))
        XCTAssertEqual(actual.map(\.data), expected)
        XCTAssertTrue(actual.allSatisfy { $0.modelID == encoder.modelID })
        print("Embedding batch (64 passages): serial=\(serialTime), two workers=\(parallelTime)")
    }

    func testCancelledEmbeddingBatchDoesNotPublishResults() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EmbeddingWorkers.shared.encode([EmbeddingInput(id: 1, text: "Cancelled indexing")])
        }
        do { _ = try await task.value; XCTFail("Cancelled work must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSmallCollectionSemanticSearchDoesNotDependOnBucketRecall() async throws {
        guard SemanticEncoder().isAvailable else { throw XCTSkip("Local sentence model unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "The project rejected the original database design."
        try Data(text.utf8).write(to: folder.appendingPathComponent("decision.md"))
        let url = root.appendingPathComponent("index.sqlite")
        let engine = try SearchEngine(databaseURL: url)
        let source = try await engine.addSource(url: folder)
        try await engine.scan(sourceID: source.id)
        let database = try Database(url: url)
        XCTAssertEqual(try database.rows("SELECT COUNT(*) AS n FROM vector_buckets").first?.int("n"), 0)
        let results = try await engine.search(SearchRequest(query: text, mode: .semantic, sourceID: source.id))
        XCTAssertEqual(results.first?.filename, "decision.md")
    }

    func test_quantization_when_denseVector_expects_compactAccurateUnitVector() {
        var random = SeededRandom(seed: 71)
        let vector = (0..<768).map { _ in random.nextFloat() }
        let packed = SemanticEncoder.pack(vector)
        let decoded = SemanticEncoder.unpack(packed)

        XCTAssertEqual(packed.count, 12 + vector.count)
        XCTAssertEqual(decoded.count, vector.count)
        XCTAssertGreaterThan(SemanticEncoder.cosine(vector, decoded), 0.9999)
        XCTAssertEqual(decoded.reduce(0.0) { $0 + Double($1) * Double($1) }, 1, accuracy: 0.00001)
        XCTAssertEqual(packed, SemanticEncoder.pack(vector))
    }

    func test_quantization_when_sparseSignedVector_expects_preservedDirections() {
        let vector: [Float] = [0, -100, 0, 100, 0]
        let decoded = SemanticEncoder.unpack(SemanticEncoder.pack(vector))
        XCTAssertEqual(decoded[0], 0)
        XCTAssertLessThan(decoded[1], 0)
        XCTAssertGreaterThan(decoded[3], 0)
        XCTAssertEqual(SemanticEncoder.cosine(vector, decoded), 1, accuracy: 0.000001)
    }

    func test_vectors_when_invalid_expects_emptyEncodingAndBuckets() {
        let invalid: [[Float]] = [[], [0, 0], [.nan, 1], [.infinity, 0], [-.infinity],
                                 Array(repeating: 1, count: 4_097)]
        for vector in invalid {
            XCTAssertTrue(SemanticEncoder.pack(vector).isEmpty)
            XCTAssertTrue(SemanticEncoder.buckets(for: vector).isEmpty)
            XCTAssertTrue(SemanticEncoder.queryBuckets(for: vector).isEmpty)
            XCTAssertEqual(SemanticEncoder.cosine(vector, vector), 0)
        }
    }

    func test_cosine_when_extremeFiniteValues_expects_stableSimilarity() {
        let largest = Float.greatestFiniteMagnitude
        let smallest = Float.leastNonzeroMagnitude
        XCTAssertEqual(SemanticEncoder.cosine([largest, largest], [1, 1]), 1, accuracy: 0.000001)
        XCTAssertEqual(SemanticEncoder.cosine([smallest, smallest], [1, 1]), 1, accuracy: 0.000001)
        XCTAssertEqual(SemanticEncoder.cosine([1, 2], [-1, -2]), -1, accuracy: 0.000001)
        XCTAssertEqual(SemanticEncoder.cosine([1, 0], [0, 1]), 0)
        XCTAssertEqual(SemanticEncoder.cosine([1], [1, 2]), 0)
        XCTAssertFalse(SemanticEncoder.pack([largest, largest]).isEmpty)
        XCTAssertFalse(SemanticEncoder.pack([smallest, smallest]).isEmpty)
    }

    func test_unpack_when_corruptBlob_expects_emptyVector() {
        let valid = SemanticEncoder.pack([1, -2, 3])
        var badMagic = valid
        badMagic[0] = 0
        var badDimension = valid
        badDimension[4] = 0xFF
        var invalidScale = valid
        invalidScale.replaceSubrange(8..<12, with: [0, 0, 0x80, 0x7F]) // Positive infinity.
        var reservedByte = valid
        reservedByte[12] = 0x80
        var allZero = valid
        allZero.replaceSubrange(12..<valid.count, with: [0, 0, 0])
        let malformed = [Data(), Data([0x46]), Data(valid.dropLast()), valid + Data([0]),
                         badMagic, badDimension, invalidScale, reservedByte, allZero]
        for blob in malformed {
            XCTAssertTrue(SemanticEncoder.unpack(blob).isEmpty)
        }
    }

    func test_buckets_when_validVector_expects_deterministicTablePrefixes() {
        let vector: [Float] = [1, -2, 3, -4, 5, -6, 7, -8]
        let buckets = SemanticEncoder.buckets(for: vector)
        XCTAssertEqual(buckets.count, 10)
        XCTAssertEqual(Set(buckets).count, 10)
        XCTAssertEqual(buckets.map { $0 >> 12 }, Array(0..<10).map(Int64.init))
        XCTAssertEqual(buckets, SemanticEncoder.buckets(for: vector))
        XCTAssertEqual(buckets, SemanticEncoder.buckets(for: vector.map { $0 * 100 }))
        // This fixture detects accidental changes that require an index version migration.
        XCTAssertEqual(buckets, [1803, 4934, 10630, 14052, 20368, 24421, 28585, 31397, 36809, 39667])
    }

    func test_queryBuckets_when_validVector_expects_boundedNearbyProbes() {
        let vector: [Float] = [0.13, -0.24, 0.31, -0.48, 0.57, -0.61, 0.79, -0.88]
        let indexed = SemanticEncoder.buckets(for: vector)
        let queried = SemanticEncoder.queryBuckets(for: vector)
        XCTAssertEqual(queried.count, 930)
        XCTAssertEqual(Set(queried).count, queried.count)
        XCTAssertEqual(Array(queried.prefix(10)), indexed)
        XCTAssertEqual(queried, SemanticEncoder.queryBuckets(for: vector))
        for table in 0..<10 {
            let probes = queried.filter { $0 >> 12 == Int64(table) }
            XCTAssertEqual(probes.count, 93)
            let distances = probes.map { ($0 ^ indexed[table]).nonzeroBitCount }.sorted()
            XCTAssertEqual(distances, [0] + Array(repeating: 1, count: 8) +
                Array(repeating: 2, count: 28) + Array(repeating: 3, count: 56))
        }
    }

    func test_approximateLookup_when_seededCorrelatedCorpus_expects_highToyRecall() {
        // This guards algorithm wiring on an easy synthetic set, not production recall.
        // Retrieval consults bucket postings; it never scans vectors for candidate selection.
        var random = SeededRandom(seed: 823)
        let centers = (0..<24).map { _ in (0..<64).map { _ in random.nextFloat() } }
        let vectors = centers.flatMap { center in
            (0..<4).map { _ in center.map { $0 + random.nextFloat() * 0.18 } }
        }
        var postings: [Int64: Set<Int>] = [:]
        for (index, vector) in vectors.enumerated() {
            for bucket in SemanticEncoder.buckets(for: vector) {
                postings[bucket, default: []].insert(index)
            }
        }
        var hits = 0
        var candidatesVisited = 0
        for center in centers {
            let query = center.map { $0 + random.nextFloat() * 0.12 }
            let exact = vectors.indices.max {
                SemanticEncoder.cosine(query, vectors[$0]) < SemanticEncoder.cosine(query, vectors[$1])
            }
            let candidates = SemanticEncoder.queryBuckets(for: query).reduce(into: Set<Int>()) {
                $0.formUnion(postings[$1] ?? [])
            }
            candidatesVisited += candidates.count
            if let exact, candidates.contains(exact) { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(centers.count), 0.90)
        XCTAssertLessThan(candidatesVisited, centers.count * vectors.count / 2)
    }

    func test_encode_when_modelInstalled_expects_finiteSemanticVector() throws {
        let encoder = SemanticEncoder()
        guard encoder.isAvailable else { throw XCTSkip("The local English sentence model is unavailable in this process.") }
        XCTAssertNil(encoder.encode(" \n\t "))
        let vector = try XCTUnwrap(encoder.encode("The project rejected the original database design."))
        XCTAssertFalse(vector.isEmpty)
        XCTAssertTrue(vector.allSatisfy(\.isFinite))
        XCTAssertEqual(SemanticEncoder.cosine(vector, vector), 1, accuracy: 0.000001)
        XCTAssertTrue(encoder.modelID.contains("apple-nl-sentence-en-r"))
        XCTAssertTrue(encoder.modelID.contains("lsh10x12-p8r3-v2"))
    }

    func test_realParaphraseCandidates_when_modelInstalled_expects_retrievedEvidence() throws {
        let encoder = SemanticEncoder()
        guard encoder.isAvailable else { throw XCTSkip("Local sentence model is unavailable in this process.") }
        let cases: [(query: String, passage: String)] = [
            ("Why did we abandon the first database approach?",
             "We rejected the original database design because it could not support concurrent writes and reliable crash recovery."),
            ("Where is the spreadsheet showing last quarter's spending?",
             "The finance workbook tracks quarterly expenses across travel, software subscriptions, equipment, and contractor payments."),
            ("What did the team decide about working from home?",
             "Staff may work remotely three days each week. Department meetings will continue in the office on Tuesdays and Thursdays."),
            ("Which document explains keeping network search working without wifi?",
             "When a shared drive disconnects, the application retains its local index and cached passages so users can search offline."),
            ("Find the instructions for restoring deleted files.",
             "Recovery procedure: open the backup utility, locate the missing document in yesterday's snapshot, and restore it to the original directory."),
            ("Why were the scans difficult to read?",
             "Optical character recognition accuracy declined because the source pages were blurred, rotated, and photographed under uneven lighting."),
            ("When does the lease expire?",
             "The rental agreement terminates on December 31. The tenant must give sixty days notice before moving out."),
            ("How do we stop one broken share from blocking the whole index?",
             "Each network source has an independent queue and checkpoint. Unavailable hosts are retried separately while healthy locations continue indexing."),
            ("Show me the slide about making the database smaller.",
             "Storage optimization: quantize embedding vectors to signed bytes, compress extracted passages, and reclaim deleted entries during maintenance."),
            ("What protects private files when access is removed?",
             "On confirmation of revoked permissions, suppress cached search results and remove the affected content from the searchable index."),
            ("How can we detect modifications missed during a disconnection?",
             "Periodic reconciliation enumerates remote directories and compares metadata with the persisted manifest. Full fingerprint verification detects byte changes."),
            ("Find the recipe for the chocolate dessert.",
             "To bake brownies, combine melted butter, cocoa powder, sugar, eggs, and flour. Bake until the center is set but still moist.")
        ]
        let vectors = try cases.map { try XCTUnwrap(encoder.encode($0.passage)) }
        var postings: [Int64: Set<Int>] = [:]
        for (index, vector) in vectors.enumerated() {
            for bucket in SemanticEncoder.buckets(for: vector) {
                postings[bucket, default: []].insert(index)
            }
        }
        var intendedHits = 0
        var exactHits = 0
        for (index, item) in cases.enumerated() {
            let query = try XCTUnwrap(encoder.encode(item.query))
            let candidates = SemanticEncoder.queryBuckets(for: query).reduce(into: Set<Int>()) {
                $0.formUnion(postings[$1] ?? [])
            }
            let nearest = try XCTUnwrap(vectors.indices.max {
                SemanticEncoder.cosine(query, vectors[$0]) < SemanticEncoder.cosine(query, vectors[$1])
            })
            if candidates.contains(index) { intendedHits += 1 }
            if candidates.contains(nearest) { exactHits += 1 }
            if index == 0 {
                // Regression: the original 110-key probe missed this clear database paraphrase.
                XCTAssertTrue(candidates.contains(index))
            }
        }
        // These are candidate-stage checks on a small fixture. They do not claim that Apple's
        // model ranks intended evidence first, or establish production-scale retrieval quality.
        XCTAssertGreaterThanOrEqual(Double(exactHits) / Double(cases.count), 0.90)
        XCTAssertGreaterThanOrEqual(Double(intendedHits) / Double(cases.count), 0.75)
    }
}

private struct SeededRandom {
    var seed: UInt64

    mutating func nextFloat() -> Float {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float((seed >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF) * 2 - 1
    }
}
