import AppKit
import XCTest
@testable import FindAnythingApp

final class QuickSearchCategoryTests: XCTestCase {
    @MainActor
    func testCategorySwitchKeepsQueryAndAppsDoNotSearchDocuments() {
        let model = QuickSearchModel(library: AppModel())
        model.beginSession()
        model.setQuery("meeting")
        model.setCategory(.applications)
        XCTAssertEqual(model.query, "meeting")
        XCTAssertEqual(model.category, .applications)
        XCTAssertFalse(model.searchingDocuments)
        XCTAssertTrue(model.documents.isEmpty)
        model.setCategory(.documents)
        XCTAssertEqual(model.query, "meeting")
        XCTAssertTrue(model.applications.isEmpty)
        model.endSession()
        model.beginSession()
        XCTAssertEqual(model.category, .all)
        XCTAssertEqual(model.query, "")
        model.endSession()
    }

    @MainActor
    func testWindowHandlesCommandNumberShortcuts() throws {
        _ = NSApplication.shared
        let window = QuickSearchWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        var selected: QuickSearchCategory?
        window.selectCategory = { selected = $0 }
        for category in QuickSearchCategory.allCases {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: category.shortcut, charactersIgnoringModifiers: category.shortcut, isARepeat: false, keyCode: 0))
            XCTAssertTrue(window.performKeyEquivalent(with: event))
            XCTAssertEqual(selected, category)
        }
        selected = nil
        let modified = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        _ = window.performKeyEquivalent(with: modified)
        XCTAssertNil(selected)
    }
}
