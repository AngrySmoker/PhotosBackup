import Foundation

/// oauth_token → Android master token → Google Photos credential.
///
/// Field names and values are taken from gotohp @ 0637c745
/// (backend/googleauth.go): `exchangeOAuthToken` and `buildGooglePhotosCredential`.
/// This is a straight port of that wire format, not a reverse-engineering effort.
enum TokenExchange {

    struct Failure: LocalizedError {
        let stage: String
        let message: String
        var errorDescription: String? { "\(stage): \(message)" }
    }

    /// Result of the whole exchange. `authData` is the `&`-joined form body that
    /// `GPMCClient` already knows how to consume for the Photos API.
    struct Result {
        let androidId: String
        let email: String
        let masterToken: String
        let photosAccessToken: String
        let photosTokenExpiry: Date?
        let authData: String
        /// True when Google returned `TokenEncrypted=1` — the credential is a
        /// bound/encrypted token this probe deliberately does not decrypt.
        let encrypted: Bool
    }

    private static let authURL = URL(string: "https://android.clients.google.com/auth")!
    // First-party "android" package signature (ac2dm step).
    private static let androidSig = "38918a453d07199354f8b19af05ec6562ced5788"
    // Google Photos package signature (credential step).
    private static let photosSig = "24bb24c05e47e0aefa68a58a766179d9b613a600"

    // MARK: - Public entry

    static func run(oauthToken: String,
                    androidId: String = randomAndroidId(),
                    session: URLSession = .shared) async throws -> Result {

        let (masterToken, email, enc1) = try await exchangeOAuthToken(
            oauthToken: oauthToken, androidId: androidId, session: session)

        let cred = googlePhotosCredentialBody(androidId: androidId, email: email, masterToken: masterToken)
        let (accessToken, expiry, enc2) = try await redeemCredential(body: cred, session: session)

        return Result(
            androidId: androidId,
            email: email,
            masterToken: masterToken,
            photosAccessToken: accessToken,
            photosTokenExpiry: expiry,
            authData: cred,
            encrypted: enc1 || enc2
        )
    }

    // MARK: - Step 1: oauth_token -> master token

    static func oauthExchangeBody(oauthToken: String, androidId: String) -> [(String, String)] {
        [
            ("accountType", "HOSTED_OR_GOOGLE"),
            ("Email", "oauth-token@example.com"),   // placeholder; real value comes back
            ("has_permission", "1"),
            ("add_account", "1"),
            ("ACCESS_TOKEN", "1"),
            ("Token", oauthToken),
            ("service", "ac2dm"),
            ("source", "android"),
            ("androidId", androidId),
            ("device_country", "us"),
            ("operatorCountry", "us"),
            ("lang", "en"),
            ("sdk_version", "17"),
            ("google_play_services_version", "240913000"),
            ("client_sig", androidSig),
            ("callerSig", androidSig),
            ("droidguard_results", "dummy123"),
        ]
    }

    static func makeRequest(formPairs: [(String, String)]) -> URLRequest {
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.httpBody = Data(encodeForm(formPairs).utf8)
        req.timeoutInterval = 60
        return req
    }

    private static func exchangeOAuthToken(oauthToken: String,
                                          androidId: String,
                                          session: URLSession) async throws -> (String, String, Bool) {
        let req = makeRequest(formPairs: oauthExchangeBody(oauthToken: oauthToken, androidId: androidId))
        let (data, response) = try await send(req, session: session, stage: "master token")
        let fields = parseAuthResponse(data)

        if let err = fields["Error"] {
            throw Failure(stage: "master token",
                          message: googleError(err, url: fields["Url"], detail: fields["ErrorDetail"]))
        }
        guard let token = fields["Token"], !token.isEmpty else {
            throw Failure(stage: "master token",
                          message: "Google accepted the request but returned no master token. "
                            + "The oauth_token is likely stale — repeat the EmbeddedSetup sign-in.")
        }
        _ = response
        let email = fields["Email"].flatMap(normaliseEmail) ?? "unknown"
        let encrypted = fields["TokenEncrypted"] == "1"
        return (token, email, encrypted)
    }

    // MARK: - Step 2: master token -> Photos credential

    static func googlePhotosCredentialPairs(androidId: String, email: String, masterToken: String) -> [(String, String)] {
        [
            ("androidId", androidId),
            ("app", "com.google.android.apps.photos"),
            ("callerPkg", "com.google.android.apps.photos"),
            ("callerSig", photosSig),
            ("client_sig", photosSig),
            ("device_country", "us"),
            ("Email", email),
            ("google_play_services_version", "240913000"),
            ("lang", "en_US"),
            ("oauth2_foreground", "1"),
            ("operatorCountry", "us"),
            ("sdk_version", "33"),
            ("service", "oauth2:openid https://www.googleapis.com/auth/mobileapps.native https://www.googleapis.com/auth/photos.native"),
            ("source", "android"),
            ("Token", masterToken),
        ]
    }

    /// The `&`-joined body string `GPMCClient.AuthData` parses.
    static func googlePhotosCredentialBody(androidId: String, email: String, masterToken: String) -> String {
        encodeForm(googlePhotosCredentialPairs(androidId: androidId, email: email, masterToken: masterToken))
    }

    private static func redeemCredential(body: String,
                                        session: URLSession) async throws -> (String, Date?, Bool) {
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("GoogleAuth/1.4", forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = 60

        let (data, _) = try await send(req, session: session, stage: "photos token")
        let fields = parseAuthResponse(data)

        if let err = fields["Error"] {
            throw Failure(stage: "photos token", message: googleError(err, url: fields["Url"], detail: fields["ErrorDetail"]))
        }
        if fields["TokenEncrypted"] == "1" {
            throw Failure(stage: "photos token",
                          message: "Google returned TokenEncrypted=1 (token binding). This probe does "
                            + "not implement the bound-token key exchange; see gotohp tokenbinding.go.")
        }
        guard let auth = fields["Auth"], !auth.isEmpty else {
            throw Failure(stage: "photos token", message: "No Auth field in the response.")
        }
        let expiry = fields["Expiry"].flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        return (auth, expiry, false)
    }

    // MARK: - Networking

    private static func send(_ req: URLRequest,
                             session: URLSession,
                             stage: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Failure(stage: stage, message: "Network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(stage: stage, message: "Non-HTTP response.")
        }
        // gotohp rejects redirects here: a 3xx means the token was not usable.
        if (300..<400).contains(http.statusCode) {
            throw Failure(stage: stage, message: "Google redirected the auth request (HTTP \(http.statusCode)); "
                          + "the oauth_token was rejected.")
        }
        if http.statusCode == 200 || http.statusCode == 403 {
            // 403 still carries an Error= body worth surfacing.
            return (data, http)
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure(stage: stage, message: "HTTP \(http.statusCode). \(snippet)")
        }
        return (data, http)
    }

    // MARK: - Parsing helpers

    /// Google's auth endpoint returns `Key=Value` lines (one per line).
    static func parseAuthResponse(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    private static func googleError(_ code: String, url: String?, detail: String?) -> String {
        switch code {
        case "BadAuthentication":
            return "BadAuthentication — the oauth_token is invalid or already spent."
        case "NeedsBrowser", "DeviceManagementRequiredOrSyncDisabled":
            return "\(code) — Google wants an interactive challenge; complete it in Safari and recapture."
        default:
            var msg = code
            if let d = detail { msg += " (\(d))" }
            if let u = url { msg += " see \(u)" }
            return msg
        }
    }

    private static func normaliseEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") ? trimmed : nil
    }

    static func encodeForm(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func randomAndroidId() -> String {
        // 16 hex chars, matching gotohp's generator.
        let hex = "0123456789abcdef"
        return String((0..<16).map { _ in hex.randomElement()! })
    }
}
