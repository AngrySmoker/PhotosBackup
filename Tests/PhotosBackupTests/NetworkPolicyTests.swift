import XCTest
@testable import PhotosBackup

final class NetworkPolicyTests: XCTestCase {
    func testWiFiOnlyAllowsWiFiAndWiredSimulatorConnections() {
        XCTAssertEqual(BackupConnection.wifiOnly.decision(for: .wifi), .allowed)
        XCTAssertEqual(BackupConnection.wifiOnly.decision(for: .wired), .allowed)
    }

    func testWiFiOnlyWaitsOnCellularAndUnknownTransports() {
        XCTAssertEqual(
            BackupConnection.wifiOnly.decision(for: .cellular),
            NetworkPolicyDecision(allowsUploads: false, pauseReason: "Waiting for Wi-Fi")
        )
        XCTAssertFalse(BackupConnection.wifiOnly.decision(for: .other).allowsUploads)
    }

    func testWiFiAndCellularAllowsEveryConnectedTransport() {
        for status in [BackupNetworkStatus.wifi, .wired, .cellular, .other] {
            XCTAssertEqual(BackupConnection.wifiAndCellular.decision(for: status), .allowed)
        }
    }

    func testNoPolicyAllowsAnUnavailableConnection() {
        for policy in BackupConnection.allCases {
            XCTAssertFalse(policy.decision(for: .checking).allowsUploads)
            XCTAssertFalse(policy.decision(for: .unavailable).allowsUploads)
        }
    }
}
