import XCTest
@testable import GPMCAuthProbe

final class CredentialStoreTests: XCTestCase {

    private func result(encrypted: Bool = false, email: String = "person@gmail.com") -> TokenExchange.Result {
        let authData = TokenExchange.googlePhotosCredentialBody(
            androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master")
        return TokenExchange.Result(androidId: "0123456789abcdef", email: email,
                                    masterToken: "aas_et/master", photosAccessToken: "ya29.token",
                                    photosTokenExpiry: Date(timeIntervalSince1970: 1_900_000_000),
                                    authData: authData, encrypted: encrypted)
    }

    func testSavedCredentialSurvivesANewStoreOverTheSameSecrets() async throws {
        let secrets = MemorySecretStore()
        let saved = try await CredentialStore(secrets: secrets).save(result())
        XCTAssertEqual(saved.email, "person@gmail.com")
        XCTAssertEqual(saved.masterToken, "aas_et/master")

        // A fresh store, as on the next launch, reads the same record back.
        let reloaded = try await CredentialStore(secrets: secrets).load()
        XCTAssertEqual(reloaded, saved)
    }

    func testWhatIsSavedIsWhatGPMCClientCanConsume() async throws {
        let secrets = MemorySecretStore()
        _ = try await CredentialStore(secrets: secrets).save(result())
        let loaded = try await CredentialStore(secrets: secrets).load()
        let credential = try XCTUnwrap(loaded)
        let auth = try AuthData(credential.authData)
        XCTAssertEqual(auth.values["Email"], "person@gmail.com")
        XCTAssertEqual(auth.values["Token"], "aas_et/master")
        XCTAssertNoThrow(try GPMCClient(authData: credential.authData))
    }

    func testBoundTokenIsNeverWrittenToDisk() async {
        let secrets = MemorySecretStore()
        do {
            _ = try await CredentialStore(secrets: secrets).save(result(encrypted: true))
            XCTFail("expected a bound token to be refused")
        } catch let failure as CredentialStore.Failure {
            XCTAssertEqual(failure, .bound)
        } catch {
            XCTFail("expected CredentialStore.Failure.bound, got \(error)")
        }
        XCTAssertNil(try? secrets.read())
        XCTAssertEqual(secrets.writes, 0)
    }

    func testNoCredentialYetReadsAsNilRatherThanAnError() async throws {
        let loaded = try await CredentialStore(secrets: MemorySecretStore()).load()
        XCTAssertNil(loaded)
    }

    func testAnUnreadableBlobIsDiscardedRatherThanFailingEveryLaunch() async {
        let secrets = MemorySecretStore(Data("not json".utf8))
        do {
            _ = try await CredentialStore(secrets: secrets).load()
            XCTFail("expected the corrupt blob to be reported")
        } catch let failure as CredentialStore.Failure {
            XCTAssertEqual(failure, .corrupt)
        } catch {
            XCTFail("expected CredentialStore.Failure.corrupt, got \(error)")
        }
        XCTAssertNil(try? secrets.read())
    }

    func testClearRemovesTheStoredCredential() async throws {
        let secrets = MemorySecretStore()
        let store = CredentialStore(secrets: secrets)
        _ = try await store.save(result())
        await store.clear()
        XCTAssertNil(try secrets.read())
        let reloaded = try await store.load()
        XCTAssertNil(reloaded)
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "dev.gpmc.authprobe.tests", account: UUID().uuidString)
        addTeardownBlock { try? store.delete() }
        do {
            try store.write(Data("first".utf8))
        } catch {
            // An unsigned simulator build can be refused a keychain item
            // (errSecMissingEntitlement). That is an environment limitation,
            // not a bug in the store, so skip rather than fail.
            throw XCTSkip("Keychain unavailable in this build: \(error.localizedDescription)")
        }
        XCTAssertEqual(try store.read(), Data("first".utf8))
        try store.write(Data("second".utf8))
        XCTAssertEqual(try store.read(), Data("second".utf8), "a second write must update, not duplicate")
        try store.delete()
        XCTAssertNil(try store.read())
        XCTAssertNoThrow(try store.delete(), "deleting a missing item is not an error")
    }
}

@MainActor
final class PhotosAccountTests: XCTestCase {

    private func result(email: String = "person@gmail.com", encrypted: Bool = false) -> TokenExchange.Result {
        TokenExchange.Result(androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master",
                             photosAccessToken: "ya29.token", photosTokenExpiry: nil,
                             authData: TokenExchange.googlePhotosCredentialBody(
                                androidId: "0123456789abcdef", email: email, masterToken: "aas_et/master"),
                             encrypted: encrypted)
    }

    func testRestoreWithNothingStoredIsDisconnected() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.restore()
        XCTAssertEqual(account.status, .disconnected)
        XCTAssertNil(account.currentClient())
    }

    func testConnectThenRestoreKeepsTheAccount() async {
        let secrets = MemorySecretStore()
        let account = PhotosAccount(store: CredentialStore(secrets: secrets))
        await account.connect(result())
        XCTAssertTrue(account.status.isUsable)
        XCTAssertNotNil(account.currentClient())

        let relaunched = PhotosAccount(store: CredentialStore(secrets: secrets))
        await relaunched.restore()
        XCTAssertEqual(relaunched.status.email, "person@gmail.com")
        XCTAssertTrue(relaunched.status.isUsable)
    }

    func testBoundTokenLeavesTheAccountRejectedNotConnected() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.connect(result(encrypted: true))
        XCTAssertFalse(account.status.isUsable)
        guard case .rejected(_, let reason) = account.status else { return XCTFail("expected .rejected") }
        XCTAssertTrue(reason.contains("bound"))
        XCTAssertNil(account.currentClient())
    }

    func testOnlyCredentialErrorsChangeTheAccountState() async {
        let account = PhotosAccount(store: CredentialStore(secrets: MemorySecretStore()))
        await account.connect(result())
        account.report(GPMCError(kind: .transport, message: "no network"))
        XCTAssertTrue(account.status.isUsable, "a network blip must not disconnect the account")
        account.report(GPMCError(kind: .server(500), message: "boom"))
        XCTAssertTrue(account.status.isUsable)
        account.report(GPMCError(kind: .credentialRejected, message: "Connect the account again."))
        XCTAssertFalse(account.status.isUsable)
        XCTAssertEqual(account.status.email, "person@gmail.com")
        XCTAssertNil(account.currentClient())
    }

    func testDisconnectClearsTheStoredCredential() async {
        let secrets = MemorySecretStore()
        let account = PhotosAccount(store: CredentialStore(secrets: secrets))
        await account.connect(result())
        await account.disconnect()
        XCTAssertEqual(account.status, .disconnected)
        XCTAssertNil(try? secrets.read())
    }
}
