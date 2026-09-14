import XCTest
@testable import FindAnythingCore

final class EngineTests: XCTestCase {
    private var workspace: URL!
    private var sourceURL: URL!
    private var indexURL: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnythingTests-"+UUID().uuidString,isDirectory:true)
        sourceURL = workspace.appendingPathComponent("documents",isDirectory:true)
        indexURL = workspace.appendingPathComponent("index/catalog.sqlite")
        try FileManager.default.createDirectory(at:sourceURL,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { if let workspace { try? FileManager.default.removeItem(at:workspace) } }
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = sourceURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url)
        return url
    }
    private func makeEngine() async throws -> (SearchEngine,SourceRecord) {
        let engine = try SearchEngine(databaseURL:indexURL)
        let source = try await engine.addSource(url:sourceURL)
        return (engine,source)
    }

    func testScopedReconciliationUpdatesRenamesAndDeletesWithoutScanningOtherFolders() async throws {
        let original = try write("notes/old.md", "Old cdcphrase")
        let untouched = try write("unrelated/stable.md", "Preserved stablephrase")
        let (engine, source) = try await makeEngine()
        try await engine.scan(sourceID: source.id)
        try FileManager.default.moveItem(at: original, to: sourceURL.appendingPathComponent("notes/renamed.md"))
        _ = try write("notes/new.md", "New cdcphrase")
        // An unreported change outside the requested scope must not be scanned or deleted.
        try FileManager.default.removeItem(at: untouched)
        try await engine.scan(sourceID: source.id, scopes: ["notes"])
        let results = try await engine.search(SearchRequest(query: "cdcphrase", mode: .exact))
        XCTAssertEqual(Set(results.map(\.filename)), ["renamed.md", "new.md"])
        let preserved = try await engine.search(SearchRequest(query: "stablephrase", mode: .exact))
        XCTAssertEqual(preserved.count, 1)
        try FileManager.default.removeItem(at: sourceURL.appendingPathComponent("notes"))
        try await engine.scan(sourceID: source.id, scopes: ["notes"])
        let removed = try await engine.search(SearchRequest(query: "cdcphrase", mode: .exact))
        XCTAssertTrue(removed.isEmpty)
    }

    func testSameSizeEditWithPreservedModificationTimeIsReindexed() async throws {
        let file = try write("notes/change.md", "oldtoken")
        let stamp = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        let (engine, source) = try await makeEngine()
        try await engine.scan(sourceID: source.id)
        _ = try write("notes/change.md", "newtoken")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        try await engine.scan(sourceID: source.id, scopes: ["notes"])
        let old = try await engine.search(SearchRequest(query: "oldtoken", mode: .exact))
        let new = try await engine.search(SearchRequest(query: "newtoken", mode: .exact))
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.count, 1)
    }

    func testInterruptedScopedScanRecoversWithFullReconciliation() async throws {
        _ = try write("notes/a.md", "recoverphrase")
        _ = try write("other/b.md", "recoverphrase")
        let (engine, source) = try await makeEngine()
        try await engine.scan(sourceID: source.id)
        // Simulate persisted state left by a process termination during a scoped scan.
        try await engine.database.execute("UPDATE sources SET scan_generation='interrupted',scan_scopes='scoped' WHERE id=?", [.text(source.id)])
        try await engine.database.execute("INSERT OR REPLACE INTO scan_directories(source_id,relative_path,done) VALUES(?,'notes',1)", [.text(source.id)])
        try await engine.scan(sourceID: source.id, scopes: ["notes"])
        let results = try await engine.search(SearchRequest(query: "recoverphrase", mode: .exact))
        XCTAssertEqual(results.count, 2)
    }

    func testIndexPersistsAndDeduplicatesContentWithoutMergingLocations() async throws {
        _ = try write("alpha.md","# Architecture\nWe rejected the old database because replication was unreliable.")
        _ = try write("copies/duplicate.md","# Architecture\nWe rejected the old database because replication was unreliable.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let found = try await engine.search(SearchRequest(query:"replication",mode:.exact))
        XCTAssertEqual(found.count,2)
        XCTAssertEqual(Set(found.map(\.path)).count,2)
        XCTAssertEqual(found[0].passages.first?.id,found[1].passages.first?.id)
        XCTAssertEqual(found[0].passages.first?.line,1)
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.files,2)
        XCTAssertEqual(stats.passages,1)
        let reopened = try SearchEngine(databaseURL:indexURL)
        let persisted = try await reopened.search(SearchRequest(query:"replication",mode:.exact))
        XCTAssertEqual(persisted.count,2)
    }

    func testChangedContentAtomicallyReplacesOldPassages() async throws {
        _ = try write("decision.md","The unique formerchoice was unreliable.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let old = try await engine.search(SearchRequest(query:"formerchoice",mode:.exact))
        _ = try write("decision.md","The currentchoice was selected for durability and consistency.")
        try await engine.scan(sourceID:source.id)
        let obsolete = try await engine.search(SearchRequest(query:"formerchoice",mode:.exact))
        let current = try await engine.search(SearchRequest(query:"currentchoice",mode:.exact))
        XCTAssertTrue(obsolete.isEmpty)
        XCTAssertEqual(current.count,1)
        XCTAssertEqual(old.first?.fileID,current.first?.fileID)
        XCTAssertNotEqual(old.first?.passages.first?.id,current.first?.passages.first?.id)
    }

    func testOfflineContentPolicyAppliesToSearchAndPreview() async throws {
        _ = try write("architecture.md","The hiddenphrase explains our database decision.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        try FileManager.default.moveItem(at:sourceURL,to:workspace.appendingPathComponent("disconnected"))
        // Bookmarks can follow a renamed local directory; removing the source content simulates an unavailable mount.
        try FileManager.default.removeItem(at:workspace.appendingPathComponent("disconnected"))
        try await engine.refreshAvailability()
        let cached = try await engine.search(SearchRequest(query:"hiddenphrase",mode:.exact))
        XCTAssertEqual(cached.first?.availability,.offline)
        XCTAssertFalse(cached.first?.passages.isEmpty ?? true)
        var config = try await engine.sources()[0]
        config.allowsOfflineContent = false
        try await engine.updateSource(config)
        let content = try await engine.search(SearchRequest(query:"hiddenphrase",mode:.exact))
        let names = try await engine.search(SearchRequest(query:"architecture.md",mode:.exact))
        XCTAssertTrue(content.isEmpty)
        XCTAssertEqual(names.count,1)
        XCTAssertTrue(names[0].passages.isEmpty)
        let preview = try await engine.preview(fileID:names[0].fileID)
        XCTAssertTrue(preview.isEmpty)
        try await engine.setSourcePaused(id:source.id,paused:true)
        let pausedContent = try await engine.search(SearchRequest(query:"hiddenphrase",mode:.exact))
        XCTAssertTrue(pausedContent.isEmpty,"Pausing a disconnected source must not expose cached content")
        let pausedPreview = try await engine.preview(fileID:names[0].fileID)
        XCTAssertTrue(pausedPreview.isEmpty)
        try await engine.setSourcePaused(id:source.id,paused:false)
        do { try await engine.scan(sourceID:source.id); XCTFail("Offline scan must fail without deleting") } catch {}
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.files,1)
    }

    func testCompleteScanDeletesMissingFiles() async throws {
        let url = try write("removed.md","Obsoletemarker content.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        try FileManager.default.removeItem(at:url)
        try await engine.scan(sourceID:source.id)
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.files,0)
        XCTAssertEqual(stats.passages,0)
        XCTAssertEqual(stats.vectors,0)
    }

    func testCancelledScanPreservesCatalogAndResumes() async throws {
        _ = try write("first.md","Stablemarker must survive interruption.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        _ = try write("second.md","Pendingmarker will appear after resuming.")
        do {
            try await engine.scan(sourceID:source.id,progress:{ _ in try? await engine.setSourcePaused(id:source.id,paused:true) })
            XCTFail("Expected pause to cancel")
        } catch is CancellationError {}
        let previous = try await engine.search(SearchRequest(query:"stablemarker",mode:.exact))
        XCTAssertEqual(previous.count,1)
        try await engine.setSourcePaused(id:source.id,paused:false)
        try await engine.scan(sourceID:source.id)
        let resumed = try await engine.search(SearchRequest(query:"pendingmarker",mode:.exact))
        XCTAssertEqual(resumed.count,1)
    }

    func testExclusionsRemoveCachedContentImmediatelyAndDoNotFollowSymlinks() async throws {
        _ = try write("public/visible.md","Visiblemarker for searching.")
        _ = try write("private/secret.md","Secretmarker should disappear.")
        let outside = workspace.appendingPathComponent("outside.md")
        try Data("Outsidecontent must not be read.".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:sourceURL.appendingPathComponent("link.md"),withDestinationURL:outside)
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        var settings = source
        settings.exclusions.append("private")
        try await engine.updateSource(settings)
        let secret = try await engine.search(SearchRequest(query:"secretmarker",mode:.exact))
        let outsideMatches = try await engine.search(SearchRequest(query:"outsidecontent",mode:.exact))
        XCTAssertTrue(secret.isEmpty)
        XCTAssertTrue(outsideMatches.isEmpty)
        try await engine.scan(sourceID:source.id)
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.files,1)
    }

    func testPermissionRevocationSuppressesDuplicateOnlyInAffectedScope() async throws {
        let url = try write("restricted.md","Duplicated confidentialmarker text.")
        _ = try write("allowed.md","Duplicated confidentialmarker text.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        try FileManager.default.setAttributes([.posixPermissions:0],ofItemAtPath:url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) }
        let matches = try await engine.search(SearchRequest(query:"confidentialmarker",mode:.exact))
        XCTAssertEqual(matches.map(\.filename),["allowed.md"])
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.passages,1)
    }

    func testFullFingerprintVerificationDetectsSameSizeAndTimeChanges() async throws {
        let url = try write("preserved.md","Originalmarker text")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let modified = try url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate!
        try Data("Replacedmarker text".utf8).write(to:url)
        try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:url.path)
        try await engine.scan(sourceID:source.id,verifyAll:true)
        let original = try await engine.search(SearchRequest(query:"originalmarker",mode:.exact))
        let replacement = try await engine.search(SearchRequest(query:"replacedmarker",mode:.exact))
        XCTAssertTrue(original.isEmpty)
        XCTAssertEqual(replacement.count,1)
    }

    func testUnsupportedFormatsRemainDiscoverableAndFiltersWork() async throws {
        _ = try write("budget.custom","Invisibleunsupported body.")
        _ = try write("budget.md","Supportedcontent with FY2026-Q3 identifier.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let metadata = try await engine.search(SearchRequest(query:"budget.custom",mode:.exact))
        XCTAssertEqual(metadata.first?.status,.unsupported)
        let filtered = try await engine.search(SearchRequest(query:"budget",mode:.exact,fileExtension:"md"))
        XCTAssertEqual(filtered.map(\.filename),["budget.md"])
        let hidden = try await engine.search(SearchRequest(query:"invisibleunsupported",mode:.exact))
        XCTAssertTrue(hidden.isEmpty)
        for query in ["\"", "*", "NEAR(foo OR bar)", "FY2026-Q3", "\" OR 1=1; --", "🙂"] {
            _ = try await engine.search(SearchRequest(query:query,mode:.exact))
            _ = try await engine.search(SearchRequest(query:query,mode:.hybrid))
        }
    }

    func testSourceDeduplicationAndCacheRemovalLeaveOriginalsUntouched() async throws {
        let url = try write("original.md","Keep original bytes intact.")
        let (engine,source) = try await makeEngine()
        let same = try await engine.addSource(url:sourceURL)
        XCTAssertEqual(source.id,same.id)
        try await engine.scan(sourceID:source.id)
        try await engine.removeSource(id:source.id)
        let stats = try await engine.statistics()
        XCTAssertEqual(stats.files,0)
        XCTAssertEqual(stats.passages,0)
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"Keep original bytes intact.")
    }

    func testIdenticalBytesWithDifferentFormatsUseIndependentExtraction() async throws {
        let body = "<html><body><p>Visiblemarker</p><script>Hiddenmarker</script></body></html>"
        _ = try write("article.html",body)
        _ = try write("source.txt",body)
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let matches = try await engine.search(SearchRequest(query:"hiddenmarker",mode:.exact))
        XCTAssertEqual(matches.map(\.filename),["source.txt"])
    }

    func testPreviewWindowIncludesMatchBeyondFirstThreeHundredPassages() async throws {
        let text = (0..<340).map { index in "# Section \(index)\n" + (index == 330 ? "Deepuniquemarker": "Ordinary content") + " appears in this section." }.joined(separator:"\n\n")
        _ = try write("Deepuniquemarker.md",text)
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let results = try await engine.search(SearchRequest(query:"deepuniquemarker",mode:.exact))
        let match = try XCTUnwrap(results.first?.passages.first)
        XCTAssertTrue(match.text.contains("Deepuniquemarker"))
        let window = try await engine.preview(fileID:results[0].fileID,matchingPassageID:match.id)
        XCTAssertTrue(window.contains(where:{$0.id == match.id}))
        XCTAssertLessThanOrEqual(window.count,300)
    }

    func testRedirectedAncestorCannotReadOutsideSelectedRootOrExposeOldText() async throws {
        _ = try write("nested/decision.md","Oldprivateinformation must be suppressed if redirected.")
        let (engine,source) = try await makeEngine()
        try await engine.scan(sourceID:source.id)
        let nested = sourceURL.appendingPathComponent("nested")
        try FileManager.default.moveItem(at:nested,to:workspace.appendingPathComponent("original-nested"))
        let outside = workspace.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try Data("Outsidemarker must not be read".utf8).write(to:outside.appendingPathComponent("decision.md"))
        try FileManager.default.createSymbolicLink(at:nested,withDestinationURL:outside)
        let cached = try await engine.search(SearchRequest(query:"oldprivateinformation",mode:.exact))
        XCTAssertTrue(cached.isEmpty)
        try await engine.scan(sourceID:source.id)
        let redirected = try await engine.search(SearchRequest(query:"outsidemarker",mode:.exact))
        XCTAssertTrue(redirected.isEmpty)
    }
}
