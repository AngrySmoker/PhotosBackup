import Foundation
import CryptoKit

struct GPMCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AuthData {
    let values: [String: String]
    static let required = ["androidId", "client_sig", "callerSig", "device_country", "Email", "google_play_services_version", "lang", "oauth2_foreground", "sdk_version", "service", "Token"]
    init(_ text: String) throws {
        var parsed: [String: String] = [:]
        for pair in text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            func decode(_ s: Substring) -> String { String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(s) }
            parsed[decode(parts[0])] = decode(parts[1])
        }
        let missing = Self.required.filter { parsed[$0, default: ""].isEmpty }
        guard missing.isEmpty else { throw GPMCError(message: "Missing auth fields: " + missing.joined(separator: ", ")) }
        values = parsed
    }
    var body: Data {
        var values = values.filter { Self.required.contains($0.key) }
        values["app"] = "com.google.android.apps.photos"; values["callerPkg"] = "com.google.android.apps.photos"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.keys.sorted().map { key in
            key + "=" + values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

actor GPMCClient {
    private let auth: AuthData
    private let session: URLSession
    private var token = ""
    private var expiry = Date.distantPast
    private let userAgent = "com.google.android.apps.photos/49029607 (Linux; U; Android 9; en_US; Pixel XL; Build/PQ2A.190205.001; Cronet/127.0.6510.5) (gzip)"
    init(authData: String, session: URLSession = .shared) throws { auth = try AuthData(authData); self.session = session }
    private func checked(_ data: Data, _ response: URLResponse) throws -> (Data, HTTPURLResponse) {
        guard let http = response as? HTTPURLResponse else { throw GPMCError(message: "Invalid server response.") }
        guard (200..<300).contains(http.statusCode) else { throw GPMCError(message: "Google returned HTTP \(http.statusCode). Check your credentials and connection.") }
        return (data, http)
    }
    func authenticate() async throws {
        var request = URLRequest(url: URL(string: "https://android.googleapis.com/auth")!); request.httpMethod = "POST"
        request.httpBody = auth.body; request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("com.google.android.apps.photos", forHTTPHeaderField: "app")
        request.setValue(auth.values["androidId"], forHTTPHeaderField: "device")
        request.setValue("GoogleAuth/1.4 (Pixel XL PQ2A.190205.001); gzip", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request); _ = try checked(data, response)
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        if fields["TokenEncrypted"] == "1" {
            throw GPMCError(message: "Google returned an encrypted (bound) token. This build does not implement token binding; import an unbound credential.")
        }
        guard let value = fields["Auth"], !value.isEmpty else { throw GPMCError(message: "Google did not issue a token. Reimport your GPMC auth data.") }
        token = value; expiry = Date(timeIntervalSince1970: Double(fields["Expiry"] ?? "") ?? Date().addingTimeInterval(300).timeIntervalSince1970)
    }

    /// Read-only credential check: authenticate, then run a dummy hash lookup
    /// (mirrors gotohp's FindRemoteMediaByHash validation). Returns the account
    /// email echoed by nothing here, so callers just care that it does not throw.
    func validateReadAccess() async throws {
        try await authenticate()
        let dummyHash = Data(repeating: 0, count: 20)
        let check = Proto.bytes(1, Proto.bytes(1, Proto.bytes(1, dummyHash)) + Proto.bytes(2, Data()))
        _ = try await rpc("5084965799730810217", body: check)
    }
    private func request(_ url: URL, method: String = "POST", body: Data? = nil, file: URL? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        if expiry <= Date().addingTimeInterval(30) { try await authenticate() }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en_US", forHTTPHeaderField: "Accept-Language")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let result: (Data, URLResponse)
        if let file { result = try await session.upload(for: request, fromFile: file) }
        else { request.httpBody = body; result = try await session.data(for: request) }
        return try checked(result.0, result.1)
    }
    private func rpc(_ method: String, body: Data) async throws -> Data {
        try await request(URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/" + method)!, body: body, headers: ["x-goog-ext-173412678-bin": "CgcIAhClARgC", "x-goog-ext-174067345-bin": "CgIIAg=="]).0
    }
    func upload(file: URL, filename: String, useQuota: Bool, saver: Bool, phase: @Sendable (String) async -> Void) async throws -> String {
        await phase("Checking duplicates")
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hasher = Insecure.SHA1(); var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); hasher.update(data: chunk); size += UInt64(chunk.count) }
        let hash = Data(hasher.finalize())
        let check = Proto.bytes(1, Proto.bytes(1, Proto.bytes(1, hash)) + Proto.bytes(2, Data()))
        let existing = try await rpc("5084965799730810217", body: check)
        if let key = try Proto.string(at: [1, 2, 2, 1], in: existing) { await phase("Already backed up"); return key }
        await phase("Preparing upload")
        let endpoint = URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive")!
        let body = Proto.int(1, 2) + Proto.int(2, 2) + Proto.int(3, 1) + Proto.int(4, 3) + Proto.int(7, size)
        let (_, response) = try await request(endpoint, body: body, headers: ["X-Goog-Hash": "sha1=" + hash.base64EncodedString(), "X-Upload-Content-Length": String(size)])
        guard let uploadID = response.value(forHTTPHeaderField: "X-GUploader-UploadID"), !uploadID.isEmpty else { throw GPMCError(message: "Google did not return an upload ID.") }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "upload_id", value: uploadID)]
        await phase("Uploading")
        let (receipt, _) = try await request(components.url!, method: "PUT", file: file, headers: ["Content-Type": "application/octet-stream"])
        _ = try Proto.fields(receipt)
        await phase("Finalizing")
        let stamp = UInt64(max(0, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970))
        let metadata = Proto.bytes(1, receipt) + Proto.string(2, filename) + Proto.bytes(3, hash) + Proto.bytes(4, Proto.int(1, stamp) + Proto.int(2, 46_000_000)) + Proto.int(7, saver ? 1 : 3) + Proto.int(10, 1)
        let device = Proto.string(3, useQuota ? "Pixel 8" : (saver ? "Pixel 2" : "Pixel XL")) + Proto.string(4, "Google") + Proto.int(5, 28)
        let committed = try await rpc("16538846908252377752", body: Proto.bytes(1, metadata) + Proto.bytes(2, device) + Proto.bytes(3, Data([1, 3])))
        guard let key = try Proto.string(at: [1, 3, 1], in: committed) else { throw GPMCError(message: "Google rejected the upload during finalization.") }
        await phase("Backed up"); return key
    }
}
