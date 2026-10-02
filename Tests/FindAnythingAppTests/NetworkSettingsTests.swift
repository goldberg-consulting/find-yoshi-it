import XCTest
@testable import FindAnythingApp

final class NetworkSettingsTests: XCTestCase {
    func test_saved_network_survives_reload_and_blank_input_preserves_it() throws {
        let suite = "FindAnything.NetworkSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = NetworkSettings(defaults: defaults)
        XCTAssertEqual(settings.homeNetworkName, "Gondor")
        XCTAssertTrue(settings.saveHomeNetworkName("  Rivendell  "))
        XCTAssertEqual(NetworkSettings(defaults: defaults).homeNetworkName, "Rivendell")
        XCTAssertFalse(settings.saveHomeNetworkName(" \n "))
        XCTAssertEqual(NetworkSettings(defaults: defaults).homeNetworkName, "Rivendell")
    }
}
