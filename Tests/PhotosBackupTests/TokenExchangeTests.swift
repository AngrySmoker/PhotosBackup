import XCTest
@testable import PhotosBackup

final class TokenExchangeTests: XCTestCase {

    func testAndroidIdShape() {
        let id = TokenExchange.randomAndroidId()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testFormEncodingMatchesGoogleAuthExpectations() {
        let encoded = TokenExchange.encodeForm([
            ("service", "oauth2:openid https://www.googleapis.com/auth/photos.native"),
            ("Email", "person+tag@gmail.com"),
        ])
        // Spaces and ':' and '/' must be percent-encoded; '+' in the address too.
        XCTAssertEqual(
            encoded,
            "service=oauth2%3Aopenid%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fphotos.native"
            + "&Email=person%2Btag%40gmail.com"
        )
    }

    func testOAuthExchangeBodyHasEveryFieldGotohpSends() {
        let pairs = TokenExchange.oauthExchangeBody(oauthToken: "oauth_TESTVALUE", androidId: "0123456789abcdef")
        let dict = Dictionary(uniqueKeysWithValues: pairs)
        XCTAssertEqual(dict["Token"], "oauth_TESTVALUE")
        XCTAssertEqual(dict["service"], "ac2dm")
        XCTAssertEqual(dict["source"], "android")
        XCTAssertEqual(dict["accountType"], "HOSTED_OR_GOOGLE")
        XCTAssertEqual(dict["has_permission"], "1")
        XCTAssertEqual(dict["add_account"], "1")
        XCTAssertEqual(dict["ACCESS_TOKEN"], "1")
        XCTAssertEqual(dict["client_sig"], "38918a453d07199354f8b19af05ec6562ced5788")
        XCTAssertEqual(dict["callerSig"], "38918a453d07199354f8b19af05ec6562ced5788")
        XCTAssertEqual(dict["google_play_services_version"], "240913000")
        XCTAssertEqual(dict["androidId"], "0123456789abcdef")
        XCTAssertNotNil(dict["droidguard_results"])
    }

    func testPhotosCredentialBodyIsSortedAndComplete() {
        let body = TokenExchange.googlePhotosCredentialBody(
            androidId: "abcdef0123456789", email: "u@gmail.com", masterToken: "aas_et/master")
        let dict = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
            let p = pair.split(separator: "=", maxSplits: 1)
            return (String(p[0]), p.count > 1 ? String(p[1]) : "")
        })
        XCTAssertEqual(dict["app"], "com.google.android.apps.photos")
        XCTAssertEqual(dict["callerPkg"], "com.google.android.apps.photos")
        XCTAssertEqual(dict["client_sig"], "24bb24c05e47e0aefa68a58a766179d9b613a600")
        XCTAssertEqual(dict["oauth2_foreground"], "1")
        XCTAssertEqual(dict["sdk_version"], "33")
        XCTAssertEqual(dict["Token"], "aas_et%2Fmaster")
        XCTAssertTrue(dict["service"]?.contains("photos.native") ?? false)
        XCTAssertTrue(dict["service"]?.contains("mobileapps.native") ?? false)
    }

    func testRequestHeadersMatchGoogleAuthClient() {
        let req = TokenExchange.makeRequest(formPairs: [("a", "b")])
        XCTAssertEqual(req.url?.absoluteString, "https://android.clients.google.com/auth")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "GoogleAuth/1.4")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testParseAuthResponseSplitsKeyValueLines() {
        let body = Data("Token=aas_et/xyz\nEmail=Person@Gmail.com\nExpiry=1893456000\n".utf8)
        let fields = TokenExchange.parseAuthResponse(body)
        XCTAssertEqual(fields["Token"], "aas_et/xyz")
        XCTAssertEqual(fields["Email"], "Person@Gmail.com")
        XCTAssertEqual(fields["Expiry"], "1893456000")
    }

    func testParseAuthResponseKeepsBase64PaddingInValues() {
        // Auth values contain '=' — only the first '=' is the separator.
        let fields = TokenExchange.parseAuthResponse(Data("Auth=ya29.a0AeXX==\n".utf8))
        XCTAssertEqual(fields["Auth"], "ya29.a0AeXX==")
    }
}
