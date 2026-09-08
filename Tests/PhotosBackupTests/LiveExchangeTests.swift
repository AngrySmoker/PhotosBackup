import XCTest
@testable import PhotosBackup

/// Hits the real android.clients.google.com/auth endpoint. Skipped unless
/// GPMC_LIVE=1 is set, because it needs the network and (for a full pass) a
/// real, unspent oauth_token in GPMC_OAUTH_TOKEN.
final class LiveExchangeTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["GPMC_LIVE"] == "1" }

    func testInvalidTokenIsRejectedByGoogleNotByUs() async throws {
        try XCTSkipUnless(live, "set GPMC_LIVE=1 to run")

        do {
            _ = try await TokenExchange.run(oauthToken: "oauth_token_that_is_not_real")
            XCTFail("expected the exchange to throw")
        } catch let f as TokenExchange.Failure {
            // The point of the probe: the request reached Google and we parsed a
            // real rejection, rather than crashing on our own request building.
            XCTAssertEqual(f.stage, "master token")
            print("LIVE master-token rejection: \(f.message)")
        }
    }

    func testFullExchangeWithRealToken() async throws {
        try XCTSkipUnless(live, "set GPMC_LIVE=1 to run")
        guard let token = ProcessInfo.processInfo.environment["GPMC_OAUTH_TOKEN"], !token.isEmpty else {
            throw XCTSkip("set GPMC_OAUTH_TOKEN to a fresh accounts.google.com oauth_token")
        }
        let result = try await TokenExchange.run(oauthToken: token)
        print("LIVE account: \(result.email)")
        print("LIVE master token prefix: \(result.masterToken.prefix(8))")
        print("LIVE photos token prefix: \(result.photosAccessToken.prefix(8))")
        XCTAssertFalse(result.masterToken.isEmpty)
        XCTAssertFalse(result.photosAccessToken.isEmpty || result.encrypted)

        let client = try GPMCClient(authData: result.authData)
        try await client.validateReadAccess()
        print("LIVE read access: OK")
    }
}
