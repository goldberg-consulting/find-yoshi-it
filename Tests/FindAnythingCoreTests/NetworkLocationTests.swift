import Foundation
import XCTest
@testable import FindAnythingCore

final class NetworkLocationTests: XCTestCase {
    func test_remembered_share_reconnects_without_credentials_or_selected_subfolder() throws {
        let url = try XCTUnwrap(RememberedNetworkShare.reconnectURL(identity: "smbfs|//DOMAIN;user:secret@UNAS-Pro.local/Personal-Drive|/Documents"))
        XCTAssertEqual(url.absoluteString, "smb://unas-pro.local/Personal-Drive")
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
        XCTAssertEqual(RememberedNetworkShare.reconnectURL(identity: "smbfs|//guest@[2001:db8::1]:1445/Team%20Files|/")?.absoluteString, "smb://[2001:db8::1]:1445/Team%20Files")
        XCTAssertNil(RememberedNetworkShare.reconnectURL(identity: "apfs|disk|/Documents"))
        XCTAssertNil(RememberedNetworkShare.reconnectURL(identity: "smbfs|//host|/Documents"))
        XCTAssertNil(RememberedNetworkShare.reconnectURL(identity: "smbfs|//host/Share|/folder|ambiguous"))
    }

    func test_remembered_network_sources_survive_restart_and_skip_paused_sources() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let databaseURL = workspace.appendingPathComponent("library.sqlite")
        let engine = try SearchEngine(databaseURL: databaseURL)
        let source = try await engine.addSource(url: workspace)
        let database = try Database(url: databaseURL)
        try database.execute("UPDATE sources SET kind='network',identity=?,availability='offline' WHERE id=?", [.text("smbfs|//user@unas-pro.invalid/Personal-Drive|/Documents"), .text(source.id)])
        let reopened = try SearchEngine(databaseURL: databaseURL)
        let urls = try await reopened.networkReconnectURLs()
        XCTAssertEqual(urls.map(\.absoluteString), ["smb://unas-pro.invalid/Personal-Drive"])
        try await reopened.refreshAvailability()
        let retained = try await reopened.sources()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.availability, .offline)
        try database.execute("UPDATE sources SET paused=1 WHERE id=?", [.text(source.id)])
        let pausedURLs = try await reopened.networkReconnectURLs()
        XCTAssertTrue(pausedURLs.isEmpty)
    }

    func test_server_names_and_ip_addresses_produce_smb_urls() throws {
        XCTAssertEqual(try SMBAddress(" nas.local ").url.absoluteString, "smb://nas.local")
        XCTAssertEqual(try SMBAddress("192.0.2.100").host, "192.0.2.100")
        XCTAssertEqual(try SMBAddress("TEST_HOST01").host, "test_host01")
        XCTAssertEqual(try SMBAddress("[::1]").host, "::1")
        XCTAssertEqual(try SMBAddress("2001:db8::1").url.absoluteString, "smb://[2001:db8::1]")
    }

    func test_share_paths_are_encoded_without_changing_locations() throws {
        let address = try SMBAddress("SMB://nas.local/Team Files/Research notes")
        XCTAssertEqual(address.url.absoluteString, "smb://nas.local/Team%20Files/Research%20notes")
        XCTAssertEqual(address.url.path, "/Team Files/Research notes")
        XCTAssertEqual(address.displayName, "nas.local/Team Files/Research notes")
        XCTAssertEqual(try SMBAddress("nas.local/Team%20Files").url.path, "/Team Files")
        XCTAssertEqual(try SMBAddress("smb://nas.local:445/Team").url.port, 445)
    }

    func test_credentials_are_rejected_and_never_repeated_in_errors() {
        for value in ["smb://fixtureUser@nas.local/Team", "smb://fixtureUser:secret@nas.local/Team", "fixtureUser@nas.local", "smb://@nas.local", "smb://DOMAIN;fixtureUser@nas.local/Team"] {
            XCTAssertThrowsError(try SMBAddress(value)) { error in
                XCTAssertEqual(error as? SMBAddressError, .credentialsNotAllowed)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                XCTAssertFalse(error.localizedDescription.contains("fixtureUser@"))
            }
        }
    }

    func test_invalid_and_non_smb_addresses_are_rejected() {
        let invalid = ["", " ", "https://nas.local/Team", "file:///Volumes/Team", "ftp://nas.local", "smb://", "smb:///Team", "smb:server", "smb://nas.local?password=secret", "smb://nas.local/Team#fragment", "smb://nas.local:0", "smb://nas.local:65536", "smb://bad host/Team", "smb://host%2Fother/Team", "smb://host%40other/Team", "smb://host/Team/%00", "smb://host/Team/%ZZ", "smb://host/Team/../Private", "smb://host/Team/%2e%2e/Private", "smb://host/Team\\Private", "smb://host\n/Team", "999.168.1.100", "smb://nas..local", "smb://-nas.local", "smb://[not:ipv6]"]
        for value in invalid { XCTAssertThrowsError(try SMBAddress(value), "Accepted invalid address: \(value)") }
    }

    func test_mount_fixture_strips_credentials_and_preserves_mount_path() throws {
        let share = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//DOMAIN;fixtureUser:secret@nas.local/Team%20Files", mountedOn: "/Volumes/Team Files-1"))
        XCTAssertEqual(share.name, "Team Files")
        XCTAssertEqual(share.server, "nas.local")
        XCTAssertEqual(share.path, "/Volumes/Team Files-1")
        XCTAssertTrue(share.id.hasPrefix(share.path + "|"))
        XCTAssertEqual(share.identityToken.count, 64)
        XCTAssertFalse(String(describing: share).contains("secret"))
        XCTAssertFalse(String(describing: share).contains("DOMAIN"))
    }

    func test_mount_fixture_accepts_guest_and_ipv6_shares() throws {
        let guest = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//nas.local/Public", mountedOn: "/Volumes/Public/"))
        XCTAssertEqual(guest.path, "/Volumes/Public")
        let ipv6 = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//guest@[2001:db8::1]/Research", mountedOn: "/Volumes/Research"))
        XCTAssertEqual(ipv6.server, "2001:db8::1")
        let punctuation = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//nas.local/Team #1", mountedOn: "/Volumes/Team #1"))
        XCTAssertEqual(punctuation.name, "Team #1")
    }

    func test_replaced_mount_at_same_path_changes_identity_for_another_user_or_server() throws {
        let fixtureUser = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//fixtureUser@nas.local/Team", mountedOn: "/Volumes/Team"))
        let repeated = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//fixtureUser@nas.local/Team", mountedOn: "/Volumes/Team/"))
        let otherUser = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//other@nas.local/Team", mountedOn: "/Volumes/Team"))
        let otherServer = try XCTUnwrap(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//fixtureUser@other.local/Team", mountedOn: "/Volumes/Team"))
        XCTAssertEqual(fixtureUser, repeated)
        XCTAssertNotEqual(fixtureUser, otherUser)
        XCTAssertNotEqual(fixtureUser.id, otherUser.id)
        XCTAssertNotEqual(fixtureUser.identityToken, otherServer.identityToken)
        XCTAssertFalse(fixtureUser.id.contains("fixtureUser@"))
    }

    func test_mount_path_normalization_is_lexical() {
        let share = MountedNetworkShare(path: "/Volumes/unused/../Team//", name: "Team", server: "nas.local")
        XCTAssertEqual(share.path, "/Volumes/Team")
    }

    func test_mount_fixture_ignores_other_protocols_and_malformed_entries() {
        XCTAssertNil(MountedNetworkShare.parseMount(fileSystem: "nfs", mountedFrom: "server:/share", mountedOn: "/Volumes/Share"))
        XCTAssertNil(MountedNetworkShare.parseMount(fileSystem: "apfs", mountedFrom: "/dev/disk1", mountedOn: "/"))
        XCTAssertNil(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//user@server", mountedOn: "/Volumes/Share"))
        XCTAssertNil(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//server/Share", mountedOn: "relative/path"))
        XCTAssertNil(MountedNetworkShare.parseMount(fileSystem: "smbfs", mountedFrom: "//server/Share%00", mountedOn: "/Volumes/Share"))
    }

    func test_disconnected_share_selection_does_not_create_a_source() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnythingNetworkGuard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let engine = try SearchEngine(databaseURL: workspace.appendingPathComponent("library.sqlite"))
        let path = "/Volumes/FindAnythingMissing-" + UUID().uuidString
        let share = MountedNetworkShare(path: path, name: "Disconnected", server: "nas.invalid")
        do {
            _ = try await engine.addSource(url: URL(fileURLWithPath: path, isDirectory: true), expectedNetworkShare: share)
            XCTFail("A disconnected mount must not become a source.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disconnected or changed")) }
        let sources = try await engine.sources()
        XCTAssertTrue(sources.isEmpty)
    }

    func test_share_path_mismatch_cannot_add_an_unrelated_local_folder() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("FindAnythingNetworkMismatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let local = workspace.appendingPathComponent("Unrelated local folder", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let engine = try SearchEngine(databaseURL: workspace.appendingPathComponent("library.sqlite"))
        let share = MountedNetworkShare(path: "/Volumes/Selected share", name: "Selected share", server: "nas.invalid")
        do {
            _ = try await engine.addSource(url: local, expectedNetworkShare: share)
            XCTFail("An unrelated local folder must not replace the selected share.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("disconnected or changed")) }
        let sources = try await engine.sources()
        XCTAssertTrue(sources.isEmpty)
    }
}
