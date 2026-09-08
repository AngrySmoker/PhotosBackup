import XCTest
import CryptoKit
@testable import GPMCAuthProbe

final class GPMCClientTests: XCTestCase {

    // A credential body with every field `AuthData.required` insists on.
    private static let credential = TokenExchange.googlePhotosCredentialBody(
        androidId: "0123456789abcdef", email: "person@gmail.com", masterToken: "aas_et/master+token")

    private static let farFuture = String(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))

    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    // MARK: - AuthData

    func testAuthDataRoundTripsTheCredentialTokenExchangeProduces() throws {
        let auth = try AuthData(Self.credential)
        XCTAssertEqual(auth.values["Email"], "person@gmail.com")
        // '/' and '+' are percent-encoded on the way out and must come back intact.
        XCTAssertEqual(auth.values["Token"], "aas_et/master+token")
        XCTAssertEqual(auth.values["androidId"], "0123456789abcdef")
    }

    func testAuthDataNamesTheMissingFieldsAndReadsAsARejection() {
        XCTAssertThrowsError(try AuthData("Email=a@b.com&Token=x")) { error in
            let gpmc = error as? GPMCError
            XCTAssertEqual(gpmc?.kind, .credentialRejected)
            XCTAssertTrue(gpmc?.message.contains("androidId") ?? false)
            XCTAssertTrue(gpmc?.message.contains("oauth2_foreground") ?? false)
        }
    }

    func testAuthDataBodyIsSortedAndCarriesThePhotosPackage() throws {
        let body = String(decoding: try AuthData(Self.credential).body, as: UTF8.self)
        let keys = body.split(separator: "&").map { $0.split(separator: "=")[0] }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(body.contains("app=com.google.android.apps.photos"))
        XCTAssertTrue(body.contains("callerPkg=com.google.android.apps.photos"))
        XCTAssertTrue(body.contains("Token=aas_et%2Fmaster%2Btoken"))
    }

    // MARK: - Error kinds

    /// The photosdata-pa RPCs are not uniform. gotohp @ 0637c745 sets the two
    /// x-goog-ext headers on commit / CreateAlbum / AddMediaToAlbum but not on
    /// FindRemoteMediaByHash, and Google answers the hash lookup with HTTP 400
    /// when they are present. Observed live on 2026-09-08 as a red step 9.
    func testHashLookupOmitsTheExtensionHeadersThatCommitSends() async throws {
        StubProtocol.handler = { request in
            if request.url?.host == "android.googleapis.com" {
                return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
            }
            return .ok(Data())
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try? await client.validateReadAccess()

        let lookup = StubProtocol.seen.first { $0.url?.absoluteString.hasSuffix("5084965799730810217") == true }
        let request = try XCTUnwrap(lookup, "the hash lookup was never sent")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-ext-173412678-bin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-ext-174067345-bin"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
    }

    /// A refactor once routed every request through a shared `send` helper and
    /// dropped `httpBody` on the way, so each protobuf RPC posted an empty body
    /// and Google answered 400. Nothing caught it: `body` still looked used
    /// because the re-auth retry passes it along. Assert the bytes go out.
    func testRpcActuallySendsItsProtobufBody() async throws {
        StubProtocol.handler = { request in
            if request.url?.host == "android.googleapis.com" {
                return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n")
            }
            return .ok(Data())
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        _ = try? await client.validateReadAccess()

        let lookup = StubProtocol.seen.first { $0.url?.absoluteString.hasSuffix("5084965799730810217") == true }
        let request = try XCTUnwrap(lookup, "the hash lookup was never sent")
        let sent = Self.body(of: request)
        XCTAssertFalse(sent.isEmpty, "the hash lookup posted an empty body")
        // HashCheck { field1 { field1 { sha1Hash } , field2 {} } } — the 20-byte
        // hash has to appear inside it.
        XCTAssertTrue(sent.count >= 20)
    }

    /// URLProtocol sees a streamed body, not `httpBody`, so read whichever is set.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
        }
        return out
    }

    func testRetryClassification() {
        XCTAssertTrue(GPMCError(kind: .transport, message: "x").isRetryable)
        XCTAssertTrue(GPMCError(kind: .server(503), message: "x").isRetryable)
        XCTAssertTrue(GPMCError(kind: .server(429), message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .server(400), message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .credentialRejected, message: "x").isRetryable)
        XCTAssertFalse(GPMCError(kind: .tokenBound, message: "x").isRetryable)
    }

    // MARK: - authenticate()

    func testAuthenticateAcceptsAnAuthLine() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        try await client.authenticate()
        let sent = StubProtocol.seen.first
        XCTAssertEqual(sent?.url?.absoluteString, "https://android.googleapis.com/auth")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "app"), "com.google.android.apps.photos")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "device"), "0123456789abcdef")
    }

    func testBoundTokenIsDetectedAndRejectedRatherThanUsed() async throws {
        StubProtocol.handler = { _ in .text("Auth=ya29.token\nTokenEncrypted=1\nExpiry=\(Self.farFuture)\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .tokenBound) { try await client.authenticate() }
    }

    func testErrorLineOnA200IsACredentialRejectionNotASuccess() async throws {
        StubProtocol.handler = { _ in .text("Error=BadAuthentication\n") }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.authenticate() }
    }

    func testErrorLineOnA403IsReadBeforeTheStatusCode() async throws {
        StubProtocol.handler = { _ in .text("Error=BadAuthentication\nUrl=https://accounts.google.com\n", status: 403) }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.authenticate() }
    }

    func testServerErrorIsRetryableRatherThanACredentialProblem() async throws {
        StubProtocol.handler = { _ in .text("", status: 503) }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .server(503)) { try await client.authenticate() }
    }

    // MARK: - upload()

    /// A scripted Google: auth, hash lookup, upload initiate, PUT, commit.
    private static func photosHandler(existingKey: String? = nil,
                                      committedKey: String = "MEDIAKEY") -> (URLRequest) -> StubProtocol.Reply {
        { request in
            let path = request.stubPath
            if path == "/auth" { return .text("Auth=ya29.token\nExpiry=\(farFuture)\n") }
            if path.hasSuffix("/5084965799730810217") {
                guard let existingKey else { return .ok(Data()) }
                return .ok(Proto.bytes(1, Proto.bytes(2, Proto.bytes(2, Proto.string(1, existingKey)))))
            }
            if path.hasSuffix("/16538846908252377752") {
                return .ok(Proto.bytes(1, Proto.bytes(3, Proto.string(1, committedKey))))
            }
            if request.httpMethod == "PUT" { return .ok(Proto.string(1, "receipt")) }
            return .ok(Data(), headers: ["X-GUploader-UploadID": "upload-123"])
        }
    }

    private func scratchFile(_ bytes: Int = 4096, name: String = "IMG_0001.JPG") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    func testUploadReportsPhasesInOrderAndReturnsTheCommittedKey() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile()
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let phases = PhaseRecorder()
        let outcome = try await client.upload(file: file, filename: "IMG_0001.JPG",
                                              modified: Date(timeIntervalSince1970: 1_600_000_000),
                                              useQuota: false, saver: false) { phases.record($0) }
        XCTAssertEqual(outcome, .uploaded(mediaKey: "MEDIAKEY"))
        let seen = phases.phases
        XCTAssertEqual(seen.first, .hashing(fraction: 0))
        XCTAssertTrue(seen.contains(.hashing(fraction: 1)))
        XCTAssertTrue(seen.contains(.checkingDuplicate))
        XCTAssertTrue(seen.contains(.preparing))
        XCTAssertTrue(seen.contains(.sending(sent: 0, total: 4096)))
        XCTAssertEqual(seen.last, .finalizing)

        // The initiate request must advertise the same SHA-1 and length the
        // hashing pass computed.
        let initiate = StubProtocol.seen.first { $0.httpMethod == "POST" && $0.stubPath.hasSuffix("/interactive") }
        let expected = Data(Insecure.SHA1.hash(data: try Data(contentsOf: file))).base64EncodedString()
        XCTAssertEqual(initiate?.value(forHTTPHeaderField: "X-Goog-Hash"), "sha1=" + expected)
        XCTAssertEqual(initiate?.value(forHTTPHeaderField: "X-Upload-Content-Length"), "4096")
    }

    func testAlreadyBackedUpIsDistinguishableFromAFreshUpload() async throws {
        StubProtocol.handler = Self.photosHandler(existingKey: "EXISTING")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let phases = PhaseRecorder()
        let outcome = try await client.upload(file: try scratchFile(), filename: "IMG_0002.JPG",
                                              useQuota: false, saver: false) { phases.record($0) }
        XCTAssertEqual(outcome, .alreadyBackedUp(mediaKey: "EXISTING"))
        // A duplicate never reaches the transfer phases.
        XCTAssertFalse(phases.phases.contains { if case .sending = $0 { return true }; return false })
    }

    func testEmptyFileIsRefusedBeforeAnyRequest() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile(0, name: "empty.jpg")
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        do {
            _ = try await client.upload(file: file, filename: "empty.jpg", useQuota: false, saver: false) { _ in }
            XCTFail("expected an empty file to be refused")
        } catch let error as GPMCError {
            XCTAssertTrue(error.message.contains("empty"))
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testCancellationSurfacesAsCancellationErrorNotATransportFailure() async throws {
        StubProtocol.handler = Self.photosHandler()
        let file = try scratchFile(8 * 1_048_576)
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        let task = Task {
            try await client.upload(file: file, filename: "big.jpg", useQuota: false, saver: false) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the upload to be cancelled")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testMidFlightRejectionIsRetriedOnceWithAFreshTokenThenGivenUpOn() async throws {
        // Every RPC answers 401. The client should re-authenticate once and try
        // again before reporting the credential as rejected.
        let counter = Counter()
        StubProtocol.handler = { request in
            if request.stubPath == "/auth" { return .text("Auth=ya29.token\nExpiry=\(Self.farFuture)\n") }
            counter.bump()
            return .text("", status: 401)
        }
        let client = try GPMCClient(authData: Self.credential, session: StubProtocol.session())
        await XCTAssertThrowsGPMC(kind: .credentialRejected) { try await client.validateReadAccess() }
        XCTAssertEqual(counter.value, 2, "the RPC should be attempted twice, once per token")
        XCTAssertEqual(StubProtocol.seen.filter { $0.stubPath == "/auth" }.count, 2)
    }
}

// MARK: - Helpers

final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UploadPhase] = []
    func record(_ phase: UploadPhase) { lock.lock(); storage.append(phase); lock.unlock() }
    var phases: [UploadPhase] { lock.lock(); defer { lock.unlock() }; return storage }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

func XCTAssertThrowsGPMC(kind: GPMCError.Kind, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () async throws -> Void) async {
    do {
        try await body()
        XCTFail("expected a GPMCError(\(kind))", file: file, line: line)
    } catch let error as GPMCError {
        XCTAssertEqual(error.kind, kind, error.message, file: file, line: line)
    } catch {
        XCTFail("expected a GPMCError(\(kind)), got \(error)", file: file, line: line)
    }
}
