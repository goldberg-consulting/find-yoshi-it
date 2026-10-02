import XCTest
@testable import FindAnythingApp

final class NetworkShareRecoveryTests: XCTestCase {
    @MainActor
    func test_home_wifi_gate_and_wired_or_redacted_ssid_fallback() {
        XCTAssertTrue(NetworkShareRecovery.permitsRecovery(usesWiFi: true, ssid: "Gondor", homeSSID: "Gondor"))
        XCTAssertFalse(NetworkShareRecovery.permitsRecovery(usesWiFi: true, ssid: "Coffee Shop", homeSSID: "Gondor"))
        XCTAssertTrue(NetworkShareRecovery.permitsRecovery(usesWiFi: false, ssid: nil, homeSSID: "Gondor"))
        XCTAssertTrue(NetworkShareRecovery.permitsRecovery(usesWiFi: true, ssid: nil, homeSSID: "Gondor"))
    }
}
