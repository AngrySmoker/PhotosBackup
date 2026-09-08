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
        { [self] _, _, emit in
            let step: Step = lock.sync {
                calls += 1; inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
                return steps.isEmpty ? fallback : steps.removeFirst()
            }
            defer { lock.sync { inFlight -= 1 } }
            emit(.described(name: "IMG_\(calls).JPG", byteCount: 1234))
            emit(.state(.hashing(fraction: 1)))
            emit(.state(.uploading(fraction: 0.5)))
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
