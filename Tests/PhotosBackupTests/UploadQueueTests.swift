import XCTest
@testable import PhotosBackup

/// A scripted `UploadWorker`. Each call pops the next instruction, so a test
/// can say "fail twice, then succeed" without any network.
final class WorkerScript: @unchecked Sendable {
    enum Step {
        case succeed(UploadOutcome)
        case fail(Error)
        case block            // hang until cancelled
    }
    private let lock = NSLock()
    private var steps: [Step]
    private let fallback: Step
    private(set) var calls = 0
    private var inFlight = 0
    private(set) var peakInFlight = 0

    init(_ steps: [Step], fallback: Step = .succeed(.uploaded(mediaKey: "KEY"))) {
        self.steps = steps; self.fallback = fallback
    }

    func worker() -> UploadWorker {
        { [self] _, _, _, _, emit in
            let step: Step = lock.sync {
                calls += 1; inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
                return steps.isEmpty ? fallback : steps.removeFirst()
            }
            defer { lock.sync { inFlight -= 1 } }
            await emit(.described(name: "IMG_\(calls).JPG", byteCount: 1234))
            await emit(.state(.hashing(fraction: 1)))
            await emit(.state(.uploading(fraction: 0.5)))
            switch step {
            case .succeed(let outcome): return outcome
            case .fail(let error): throw error
            case .block:
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            }
        }
    }
}

private extension NSLock {
    func sync<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

@MainActor
final class UploadQueueTests: XCTestCase {

    private func makeQueue(_ script: WorkerScript, maxConcurrent: Int = 2, maxAttempts: Int = 3) -> UploadQueue {
        // No real backoff: the retry delay is injected so the state machine runs
        // at full speed here.
        UploadQueue(worker: script.worker(), maxConcurrent: maxConcurrent, maxAttempts: maxAttempts,
                    sleeper: { _ in await Task.yield() })
    }

    private func settle(_ queue: UploadQueue, timeout: TimeInterval = 5,
                        until condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("queue never settled: \(queue.items.map { "\($0.state)" })", file: file, line: line)
    }

    private var oneSource: [MediaSource] { [.file(URL(fileURLWithPath: "/dev/null"))] }
    private func sources(_ n: Int) -> [MediaSource] {
        (0..<n).map { .file(URL(fileURLWithPath: "/tmp/item-\($0)")) }
    }

    func testSuccessfulItemEndsDoneWithTheNameAndKeyTheWorkerReported() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(queue.items.first?.mediaKey, "ABC")
        XCTAssertEqual(queue.items.first?.name, "IMG_1.JPG")
        XCTAssertEqual(queue.items.first?.byteCount, 1234)
        XCTAssertTrue(queue.isIdle)
    }

    func testAlreadyBackedUpIsItsOwnTerminalState() async {
        let script = WorkerScript([.succeed(.alreadyBackedUp(mediaKey: "OLD"))])
        let queue = makeQueue(script)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .alreadyBackedUp }
        XCTAssertEqual(queue.items.first?.mediaKey, "OLD")
        XCTAssertEqual(queue.failedCount, 0)
    }

    func testTransportFailuresRetryUpToMaxAttemptsThenFail() async {
        let error = GPMCError(kind: .transport, message: "Could not reach Google.")
        let script = WorkerScript([.fail(error), .fail(error), .fail(error)], fallback: .fail(error))
        let queue = makeQueue(script, maxConcurrent: 1, maxAttempts: 3)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .failed(reason: "Could not reach Google.", retryable: true))
        XCTAssertEqual(script.calls, 3)
        XCTAssertEqual(queue.items.first?.attempts, 3)
    }

    func testARetryableFailureThatLaterSucceedsEndsDone() async {
        let script = WorkerScript([.fail(GPMCError(kind: .server(503), message: "busy")),
                                   .succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    func testNonRetryableFailureIsAttemptedOnce() async {
        let script = WorkerScript([.fail(GPMCError(kind: .malformed, message: "Google rejected the upload."))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state, .failed(reason: "Google rejected the upload.", retryable: false))
        XCTAssertEqual(script.calls, 1)
    }

    func testExporterFailureIsReportedVerbatimAndNotRetried() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.missingAsset)])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        XCTAssertEqual(queue.items.first?.state,
                       .failed(reason: "That item is no longer in your photo library.", retryable: false))
        XCTAssertEqual(script.calls, 1)
    }

    func testCredentialRejectionHaltsTheQueueAndLeavesWorkRequeued() async {
        let rejection = GPMCError(kind: .credentialRejected, message: "Connect the account again.")
        let script = WorkerScript([.fail(rejection)], fallback: .fail(rejection))
        let queue = makeQueue(script, maxConcurrent: 1)
        var reported: Error?
        queue.onCredentialRejected = { reported = $0 }
        queue.enqueue(sources(3))
        await settle(queue) { queue.haltReason != nil }
        XCTAssertEqual(queue.haltReason, "Connect the account again.")
        XCTAssertEqual((reported as? GPMCError)?.kind, .credentialRejected)
        // Nothing is marked failed: everything waits for the account to come back.
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .queued })
        // And the queue stays stopped rather than burning through the rest.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 1)
    }

    func testResumeAfterAHaltPicksTheQueueBackUp() async {
        let rejection = GPMCError(kind: .credentialRejected, message: "Connect the account again.")
        let script = WorkerScript([.fail(rejection)], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.haltReason != nil }
        queue.resume()
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertNil(queue.haltReason)
    }

    func testNetworkPolicyPauseHoldsNewWorkAndResumesAutomatically() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        queue.enqueue(oneSource)

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(script.calls, 0)
        XCTAssertEqual(queue.items.first?.state, .queued)
        XCTAssertEqual(queue.networkPauseReason, "Waiting for Wi-Fi")

        queue.setNetworkAccess(allowed: true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 1)
        XCTAssertNil(queue.networkPauseReason)
    }

    func testLosingAllowedNetworkRequeuesInFlightWork() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting for Wi-Fi")
        await settle(queue) { queue.items.first?.state == .queued }
        XCTAssertEqual(script.calls, 1)

        queue.setNetworkAccess(allowed: true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    func testBackgroundExpirationRequeuesWorkForTheNextExecutionWindow() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.suspendForBackgroundExpiration()
        await settle(queue) { queue.items.first?.state == .queued }
        XCTAssertNotNil(queue.systemPauseReason)

        queue.resumeSystemWork()
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertNil(queue.systemPauseReason)
        XCTAssertEqual(script.calls, 2)
    }

    func testBackgroundExpirationDoesNotCancelAnIOSOwnedFileTransfer() async {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 1, count: 20),
            filename: "photo.jpg", modified: Date(), byteCount: 10,
            useQuota: false, saver: false, receipt: nil
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/photo.jpg", filename: "photo.jpg",
                                          modified: Date(), byteCount: 10, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let worker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            await emit(.state(.uploading(fraction: 0.25)))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let queue = UploadQueue(worker: worker, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.checkpoint == checkpoint }

        queue.suspendForBackgroundExpiration()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(queue.items.first?.state, .uploading(fraction: 0.25))
        XCTAssertEqual(queue.items.first?.checkpoint, checkpoint)
        queue.cancelAll()
        await settle(queue) { queue.items.first?.state == .cancelled }
    }

    func testURLSessionRelaunchOnlyPumpsCheckpointedTransfers() async {
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 3, count: 20),
            filename: "ready.jpg", modified: Date(), byteCount: 10,
            useQuota: false, saver: false, receipt: Data([1, 0])
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/ready.jpg", filename: "ready.jpg",
                                          modified: Date(), byteCount: 10, temporary: true,
                                          prepared: prepared, continuesAfterProcessExit: true)
        let normalID = UUID()
        let readyID = UUID()
        let persistence = MemoryUploadQueuePersistence(snapshot: UploadQueueSnapshot(
            version: UploadQueueSnapshot.version,
            accountIdentifier: "person@gmail.com",
            items: [
                PersistedUploadItem(id: normalID, source: .asset("normal"), name: "normal.jpg",
                                    byteCount: 0, attempts: 0, failureReason: nil, failureRetryable: false),
                PersistedUploadItem(id: readyID, source: .asset("ready"), name: "ready.jpg",
                                    byteCount: 10, attempts: 0, failureReason: nil, failureRetryable: false,
                                    checkpoint: checkpoint)
            ],
            completedSourceKeys: []
        ))
        let queue = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        queue.setNetworkAccess(allowed: false, pauseReason: "Checking")
        queue.resumeBackgroundTransferCompletions()
        queue.activateAccount("person@gmail.com")
        queue.setNetworkAccess(allowed: true)

        await settle(queue) { queue.items.first(where: { $0.id == readyID })?.state == .done }
        XCTAssertEqual(queue.items.first(where: { $0.id == normalID })?.state, .queued)
    }

    func testCloudOnlyAssetWaitsWithoutSpendingAnAttemptAndResumesInForeground() async {
        let script = WorkerScript([.fail(MediaExporter.Failure.iCloudDownloadRequired)],
                                  fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setICloudDownloadsAllowed(false)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .waitingForICloud }
        XCTAssertEqual(queue.items.first?.attempts, 0)

        queue.setICloudDownloadsAllowed(true)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(script.calls, 2)
    }

    func testAutomaticEnqueueSkipsSourcesAlreadyTrackedOrRepeatedInOneBatch() async {
        let script = WorkerScript([])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        let source = MediaSource.file(URL(fileURLWithPath: "/tmp/repeated"))

        let first = queue.enqueue([source, source], skippingExisting: true)
        let second = queue.enqueue([source], skippingExisting: true)

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
    }

    func testAutomaticEnqueueDoesNotDuplicateAnExistingFailedSource() async {
        let failure = GPMCError(kind: .malformed, message: "bad media")
        let script = WorkerScript([.fail(failure)], fallback: .fail(failure))
        let queue = makeQueue(script, maxConcurrent: 1)
        let source = MediaSource.file(URL(fileURLWithPath: "/tmp/permanent-failure"))

        queue.enqueue([source], skippingExisting: true)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        let second = queue.enqueue([source], skippingExisting: true)

        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(script.calls, 1)
    }

    func testUploadProcessingPreferencesSurviveRelaunch() {
        let suite = "UploadQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = BackupPreferences(defaults: defaults)
        first.storageSaver = true
        first.useQuota = true

        let restored = BackupPreferences(defaults: defaults)
        XCTAssertTrue(restored.storageSaver)
        XCTAssertTrue(restored.useQuota)
    }

    func testCancelledBackgroundTransportAlwaysReleasesItsCaller() async {
        let transferID = UUID()
        let request = URLRequest(url: URL(string: "https://example.com/upload")!)
        let task = Task { () -> Bool in
            do {
                _ = try await BackgroundFileUploadTransport.shared.upload(
                    request,
                    fromFile: URL(fileURLWithPath: "/tmp/does-not-exist"),
                    transferID: transferID,
                    progress: { _, _ in }
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        task.cancel()
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
        await BackgroundFileUploadTransport.shared.cancel(transferID: transferID)
    }

    func testPendingAssetQueueRestoresAfterRelaunch() async {
        let persistence = MemoryUploadQueuePersistence()
        let firstScript = WorkerScript([])
        let first = UploadQueue(worker: firstScript.worker(), maxConcurrent: 1, persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)

        let secondScript = WorkerScript([])
        let restored = UploadQueue(worker: secondScript.worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("PERSON@gmail.com")

        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items.first?.source, .asset(localIdentifier: "asset-1"))
        XCTAssertEqual(restored.items.first?.state, .queued)
        restored.setNetworkAccess(allowed: true)
        await settle(restored) { restored.items.first?.state == .done }
        XCTAssertEqual(secondScript.calls, 1)
    }

    func testUploadCheckpointRestoresAtTheTransferBoundary() async {
        let persistence = MemoryUploadQueuePersistence()
        let prepared = PreparedUpload(
            uploadURL: URL(string: "https://example.com/upload")!, hash: Data(repeating: 2, count: 20),
            filename: "IMG.JPG", modified: Date(timeIntervalSince1970: 100), byteCount: 123,
            useQuota: false, saver: true, receipt: nil
        )
        let checkpoint = UploadCheckpoint(filePath: "/tmp/staged/IMG.JPG", filename: "IMG.JPG",
                                          modified: prepared.modified, byteCount: 123,
                                          temporary: true, prepared: prepared,
                                          continuesAfterProcessExit: true)
        let firstWorker: UploadWorker = { _, _, _, _, emit in
            await emit(.checkpoint(checkpoint))
            while true { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        let first = UploadQueue(worker: firstWorker, maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")])

        await settle(first) { persistence.snapshot?.items.first?.checkpoint == checkpoint }
        XCTAssertEqual(persistence.snapshot?.items.first?.checkpoint, checkpoint)

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertEqual(restored.items.first?.checkpoint, checkpoint)
        XCTAssertEqual(restored.retainedStagingURLs, [checkpoint.fileURL])
        first.cancelAll()
    }

    func testFilePersistenceKeepsCompletedKeysOutOfTheRewrittenQueueSnapshot() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileUploadQueuePersistence(url: directory.appendingPathComponent("queue.json"))
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        XCTAssertEqual(try persistence.load()?.completedSourceKeys, [])

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        XCTAssertTrue(restored.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true).isEmpty)
    }

    func testCompletedAssetLedgerSurvivesRelaunchAndSkipsTheAsset() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        let restored = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        let accepted = restored.enqueue([.asset(localIdentifier: "asset-1")], skippingExisting: true)

        XCTAssertTrue(accepted.isEmpty)
        XCTAssertTrue(restored.items.isEmpty)
    }

    func testQueueDoesNotCrossGoogleAccounts() {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("first@gmail.com")
        first.enqueue([.asset(localIdentifier: "asset-1")])

        let second = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        second.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        second.activateAccount("second@gmail.com")

        XCTAssertTrue(second.items.isEmpty)
    }

    func testBatchLimitCountsAcceptedItemsAfterDurableDeduplication() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), maxConcurrent: 1, persistence: persistence)
        first.activateAccount("person@gmail.com")
        first.enqueue([.asset(localIdentifier: "old")], skippingExisting: true)
        await settle(first) { first.items.first?.state == .done }

        let restored = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        let accepted = restored.enqueue(
            [.asset(localIdentifier: "old"), .asset(localIdentifier: "new-1"), .asset(localIdentifier: "new-2")],
            skippingExisting: true,
            limit: 1
        )

        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(restored.items.map(\.source), [.asset(localIdentifier: "new-1")])
    }

    func testCancellingAnInFlightItemMarksItCancelledAndFreesTheSlot() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items[0].state == .cancelled && queue.items[1].state == .done }
    }

    func testCancellingAQueuedItemNeverStartsIt() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.cancel(queue.items[1].id)
        XCTAssertEqual(queue.items[1].state, .cancelled)
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items.allSatisfy { $0.state.isFinished } }
        XCTAssertEqual(script.calls, 1)
    }

    func testCancelAllStopsRunningAndQueuedItems() async {
        let script = WorkerScript([.block], fallback: .block)
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(3))
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.cancelAll()

        await settle(queue) { queue.items.allSatisfy { $0.state == .cancelled } }
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(script.calls, 1)
    }

    func testUserPauseHoldsQueuedItemsUntilResume() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(2))
        await settle(queue) { queue.items.first?.state.isWorking == true }

        queue.pauseAfterCurrentUploads()
        queue.cancel(queue.items[0].id)
        await settle(queue) { queue.items[0].state == .cancelled }
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(queue.isUserPaused)
        XCTAssertEqual(queue.items[1].state, .queued)
        XCTAssertEqual(script.calls, 1)

        queue.resumeUserPausedUploads()
        await settle(queue) { queue.items[1].state == .done }
        XCTAssertFalse(queue.isUserPaused)
        XCTAssertEqual(script.calls, 2)
    }

    func testUserPauseSurvivesQueueRestoration() async {
        let persistence = MemoryUploadQueuePersistence()
        let first = UploadQueue(worker: WorkerScript([]).worker(), persistence: persistence)
        first.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        first.activateAccount("person@gmail.com")
        first.enqueue(oneSource)
        first.pauseAfterCurrentUploads()

        let script = WorkerScript([])
        let restored = UploadQueue(worker: script.worker(), persistence: persistence)
        restored.setNetworkAccess(allowed: false, pauseReason: "Waiting")
        restored.activateAccount("person@gmail.com")
        restored.setNetworkAccess(allowed: true)
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(restored.isUserPaused)
        XCTAssertEqual(restored.items.first?.state, .queued)
        XCTAssertEqual(script.calls, 0)

        restored.resumeUserPausedUploads()
        await settle(restored) { restored.items.first?.state == .done }
        XCTAssertFalse(restored.isUserPaused)
        XCTAssertEqual(script.calls, 1)
    }

    func testRetryResetsTheAttemptCount() async {
        let error = GPMCError(kind: .malformed, message: "nope")
        let script = WorkerScript([.fail(error)], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state.isFinished == true }
        queue.retry(queue.items[0].id)
        await settle(queue) { queue.items.first?.state == .done }
        XCTAssertEqual(queue.items.first?.attempts, 1)
    }

    func testRetryIgnoresItemsThatAlreadySucceeded() async {
        let script = WorkerScript([.succeed(.uploaded(mediaKey: "ABC"))])
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(oneSource)
        await settle(queue) { queue.items.first?.state == .done }
        queue.retry(queue.items[0].id)
        XCTAssertEqual(queue.items.first?.state, .done)
        XCTAssertEqual(script.calls, 1)
    }

    func testConcurrencyStaysWithinTheLimit() async {
        let script = WorkerScript([], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 2)
        queue.enqueue(sources(8))
        await settle(queue) { queue.items.allSatisfy { $0.state == .done } }
        XCTAssertLessThanOrEqual(script.peakInFlight, 2)
        XCTAssertEqual(script.calls, 8)
    }

    func testClearFinishedKeepsWorkInProgress() async {
        let script = WorkerScript([.block], fallback: .succeed(.uploaded(mediaKey: "ABC")))
        let queue = makeQueue(script, maxConcurrent: 1)
        queue.enqueue(sources(1))
        await settle(queue) { queue.items.first?.state.isWorking == true }
        queue.clearFinished()
        XCTAssertEqual(queue.items.count, 1)
        queue.cancelAll()
        await settle(queue) { queue.items.first?.state == .cancelled }
        queue.clearFinished()
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testProgressFractionsAreMonotonicAcrossTheStates() {
        let ordered: [UploadItem.State] = [.hashing(fraction: 0), .hashing(fraction: 1), .checkingDuplicate,
                                           .uploading(fraction: 0), .uploading(fraction: 1), .finalizing, .done]
        let fractions = ordered.compactMap { $0.fraction }
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertNil(UploadItem.State.queued.fraction)
        XCTAssertEqual(UploadItem.State.done.fraction, 1)
    }

    func testPhaseMappingCoversEveryClientPhase() {
        XCTAssertEqual(UploadPhase.hashing(fraction: 0.5).itemState, .hashing(fraction: 0.5))
        XCTAssertEqual(UploadPhase.checkingDuplicate.itemState, .checkingDuplicate)
        XCTAssertEqual(UploadPhase.preparing.itemState, .uploading(fraction: 0))
        XCTAssertEqual(UploadPhase.sending(sent: 50, total: 200).itemState, .uploading(fraction: 0.25))
        XCTAssertEqual(UploadPhase.sending(sent: 1, total: 0).itemState, .uploading(fraction: 0))
        XCTAssertEqual(UploadPhase.finalizing.itemState, .finalizing)
    }
}
