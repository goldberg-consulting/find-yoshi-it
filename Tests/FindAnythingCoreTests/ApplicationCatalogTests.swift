import Foundation
import XCTest
@testable import FindAnythingCore

final class ApplicationCatalogTests: XCTestCase {
    func testDuplicateBundleIdentifiersPreferTheRunningCopy() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "Installed/Notes.app", displayName: "Notes", bundleID: "test.notes")
        try app(root, "Running/Notes.app", displayName: "Notes", bundleID: "test.notes")
        let running = root.appendingPathComponent("Running/Notes.app")
        let catalog = ApplicationCatalog(roots: [root.appendingPathComponent("Installed")], additionalRoots: { [running] })
        await catalog.refresh()
        let results = await catalog.search("notes")
        XCTAssertEqual(results.map(\.path), [running.path])
    }

    func testRunningApplicationOutsideStandardRootsMatchesPrefixBeforeExactLookup() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "dist/SampleNotes.app", displayName: "SampleNotes")
        let bundle = root.appendingPathComponent("dist/SampleNotes.app")
        let catalog = ApplicationCatalog(roots: [], additionalRoots: { [bundle] })
        await catalog.refresh()
        let results = await catalog.search("sample")
        XCTAssertEqual(results.first?.name, "SampleNotes")
    }

    func testRegisteredApplicationOutsideStandardRootsIsFoundAndRemembered() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "Project/dist/SampleNotes.app", displayName: "SampleNotes")
        let bundle = root.appendingPathComponent("Project/dist/SampleNotes.app")
        let catalog = ApplicationCatalog(roots: [], registryLookup: { name in name.lowercased() == "samplenotes" ? bundle : nil })
        await catalog.refresh()
        let exact = await catalog.search("samplenotes")
        XCTAssertEqual(exact.first?.path, bundle.path)
        let partial = await catalog.search("sample")
        XCTAssertEqual(partial.first?.name, "SampleNotes")
        try FileManager.default.removeItem(at: bundle)
        let missing = await catalog.search("samplenotes")
        XCTAssertTrue(missing.isEmpty)
    }

    func test_explicit_application_root_is_discovered_without_crawling_its_helpers() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "Finder.app", displayName: "Finder", bundleID: "com.apple.finder", extra: ["CFBundlePackageType": "FNDR"])
        try app(root, "Finder.app/Contents/Helpers/Internal Helper.app", displayName: "Internal Helper")
        let catalog = ApplicationCatalog(roots: [root.appendingPathComponent("Finder.app", isDirectory: true)])
        await catalog.refresh()
        let finder = await catalog.search("finder")
        let helpers = await catalog.search("helper")
        XCTAssertEqual(finder.first?.bundleIdentifier, "com.apple.finder")
        XCTAssertEqual(finder.count, 1)
        XCTAssertTrue(helpers.isEmpty)
    }

    func test_defaults_include_finder_as_an_explicit_leaf_without_crawling_core_services() {
        let paths = ApplicationCatalog.defaultRoots.map(\.path)
        XCTAssertTrue(paths.contains("/System/Library/CoreServices/Finder.app"))
        XCTAssertFalse(paths.contains("/System/Library/CoreServices"))
    }

    func test_discovers_application_groups_and_bundle_display_names() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "Utilities/Terminal.app", displayName: "Terminal", bundleID: "com.apple.Terminal")
        try app(root, "Firefox.app", displayName: "Mozilla Firefox", bundleID: "org.mozilla.firefox")
        try app(root, "Café.app", bundleName: "Café")
        let catalog = ApplicationCatalog(roots: [root])
        await catalog.refresh()
        let firefox = await catalog.search("firefox")
        XCTAssertEqual(firefox.first?.name, "Mozilla Firefox")
        XCTAssertEqual(firefox.first?.bundleIdentifier, "org.mozilla.firefox")
        XCTAssertEqual(firefox.first?.id, root.appendingPathComponent("Firefox.app").path)
        let terminal = await catalog.search("term")
        XCTAssertEqual(terminal.first?.path, root.appendingPathComponent("Utilities/Terminal.app").path)
        let cafe = await catalog.search("CAFE")
        XCTAssertEqual(cafe.first?.name, "Café")
    }

    func test_hides_bundle_internals_frameworks_hidden_directories_and_background_helpers() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "Editor.app", displayName: "Editor")
        try app(root, "Editor.app/Contents/Helpers/Internal Helper.app", displayName: "Internal Helper")
        try app(root, "Support.framework/Tools/Framework Helper.app", displayName: "Framework Helper")
        try app(root, ".Hidden/Hidden App.app", displayName: "Hidden App")
        try app(root, "Background Helper.app", displayName: "Background Helper", extra: ["LSBackgroundOnly": true])
        try app(root, "Menu Bar.app", displayName: "Menu Bar", extra: ["LSUIElement": true])
        let catalog = ApplicationCatalog(roots: [root])
        await catalog.refresh()
        let editor = await catalog.search("editor")
        let helpers = await catalog.search("helper", limit: 50)
        let hidden = await catalog.search("hidden")
        let menu = await catalog.search("menu")
        XCTAssertEqual(editor.count, 1)
        XCTAssertTrue(helpers.isEmpty)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(menu.first?.name, "Menu Bar")
    }

    func test_app_symlinks_are_leaves_and_directory_cycles_are_skipped() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let outside = root.appendingPathComponent("SystemApplications", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try app(outside, "Safari.app", displayName: "Safari", bundleID: "com.apple.Safari")
        try app(outside, "Secret.app", displayName: "Secret")
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Safari.app").path, withDestinationPath: "../SystemApplications/Safari.app")
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Group Alias").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Loop").path, withDestinationPath: apps.path)
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Cycle.app").path, withDestinationPath: "Cycle2.app")
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Cycle2.app").path, withDestinationPath: "Cycle.app")
        let catalog = ApplicationCatalog(roots: [apps])
        await catalog.refresh()
        let safari = await catalog.search("saf")
        XCTAssertEqual(safari.count, 1)
        XCTAssertEqual(safari.first?.path, apps.appendingPathComponent("Safari.app").path)
        let secret = await catalog.search("secret")
        let cycles = await catalog.search("cycle")
        XCTAssertTrue(secret.isEmpty)
        XCTAssertTrue(cycles.isEmpty)
    }

    func test_same_app_target_is_deduplicated_across_aliases_and_roots() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Apps", isDirectory: true)
        let target = root.appendingPathComponent("System", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try app(target, "Safari.app", displayName: "Safari")
        try FileManager.default.createSymbolicLink(atPath: apps.appendingPathComponent("Safari.app").path, withDestinationPath: target.appendingPathComponent("Safari.app").path)
        let catalog = ApplicationCatalog(roots: [apps, target, apps])
        await catalog.refresh()
        let matches = await catalog.search("safari")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.path, apps.appendingPathComponent("Safari.app").path)
    }

    func test_ranking_prefers_exact_names_then_prefixes_and_supports_acronyms() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Safari", "Safari Technology Preview", "Visual Studio Code", "Xcode", "Finder", "Photos", "Google Chrome"] {
            try app(root, name + ".app", displayName: name)
        }
        let catalog = ApplicationCatalog(roots: [root])
        await catalog.refresh()
        let exact = await catalog.search("SAFARI")
        XCTAssertEqual(exact.prefix(2).map(\.name), ["Safari", "Safari Technology Preview"])
        let prefix = await catalog.search("Saf")
        XCTAssertEqual(prefix.first?.name, "Safari")
        for query in ["VSCode", "vsc", "visual code", "vis stu", "code"] {
            let matches = await catalog.search(query)
            XCTAssertEqual(matches.first?.name, "Visual Studio Code", "Query: \(query)")
        }
        let chrome = await catalog.search("gc")
        let finder = await catalog.search("fndr")
        XCTAssertEqual(chrome.first?.name, "Google Chrome")
        XCTAssertEqual(finder.first?.name, "Finder")
        let weak = await catalog.search("sri")
        XCTAssertTrue(weak.isEmpty)
        let unrelated = await catalog.search("zqx")
        XCTAssertTrue(unrelated.isEmpty)
    }

    func test_refresh_cache_and_force_refresh_do_not_require_a_document_index() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("MissingRoot", isDirectory: true)
        try app(root, "First.app", displayName: "First")
        let catalog = ApplicationCatalog(roots: [missing, root])
        await catalog.refresh()
        try app(root, "Second.app", displayName: "Second")
        await catalog.refresh()
        let cached = await catalog.search("second")
        XCTAssertTrue(cached.isEmpty)
        await catalog.refresh(force: true)
        let updated = await catalog.search("second")
        XCTAssertEqual(updated.first?.name, "Second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library.sqlite").path))
    }

    func test_depth_limit_and_result_limits_are_bounded() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try app(root, "one/two/three/four/five/six/seven/Too Deep.app", displayName: "Too Deep")
        for index in 0..<12 { try app(root, "Example \(index).app", displayName: "Example \(index)") }
        let catalog = ApplicationCatalog(roots: [root])
        await catalog.refresh()
        let deep = await catalog.search("deep")
        let defaults = await catalog.search("example")
        let limited = await catalog.search("example", limit: 3)
        let empty = await catalog.search("  ")
        let zero = await catalog.search("example", limit: 0)
        XCTAssertTrue(deep.isEmpty)
        XCTAssertEqual(defaults.count, 8)
        XCTAssertEqual(limited.count, 3)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(zero.isEmpty)
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnythingApplications-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func app(_ root: URL, _ relative: String, displayName: String? = nil, bundleName: String? = nil, bundleID: String? = nil, extra: [String: Any] = [:]) throws {
        let contents = root.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "APPL"]
        info["CFBundleDisplayName"] = displayName
        info["CFBundleName"] = bundleName
        info["CFBundleIdentifier"] = bundleID
        info.merge(extra) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
