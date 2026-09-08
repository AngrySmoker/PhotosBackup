import Foundation
import SwiftUI

struct UploadOptions: Equatable, Sendable {
    /// Upload against the account's storage quota rather than as a device backup.
    var useQuota = false
    /// Ask Google to re-encode ("Storage saver") instead of keeping the original.
    var storageSaver = false
}

/// One row of the activity list.
struct UploadItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case waitingToRetry(attempt: Int)
        case exporting
        case hashing(fraction: Double)
        case checkingDuplicate
        case uploading(fraction: Double)
        case finalizing
        case alreadyBackedUp
        case done
        case cancelled
        case failed(reason: String, retryable: Bool)

        var isFinished: Bool {
            switch self {
            case .alreadyBackedUp, .done, .cancelled, .failed: return true
            default: return false
            }
        }
        var isWorking: Bool {
            switch self {
            case .exporting, .hashing, .checkingDuplicate, .uploading, .finalizing: return true
            default: return false
            }
        }
        /// 0…1 for a progress bar; nil where there is nothing meaningful to show.
        var fraction: Double? {
            switch self {
            case .hashing(let f): return f * 0.1
            case .checkingDuplicate: return 0.1
            case .uploading(let f): return 0.1 + f * 0.85
            case .finalizing: return 0.95
            case .alreadyBackedUp, .done: return 1
            default: return nil
            }
        }
        var label: String {
            switch self {
            case .queued: return "Waiting"
            case .waitingToRetry(let attempt): return "Retrying (attempt \(attempt + 1))"
            case .exporting: return "Preparing"
            case .hashing: return "Checking"
            case .checkingDuplicate: return "Looking for a copy"
            case .uploading: return "Uploading"
            case .finalizing: return "Finishing"
            case .alreadyBackedUp: return "Already backed up"
            case .done: return "Backed up"
            case .cancelled: return "Cancelled"
            case .failed(let reason, _): return reason
            }
        }
    }

    let id: UUID
    let source: MediaSource
    var name: String
    var byteCount: Int64
    var state: State
    var attempts: Int
    var mediaKey: String?

    init(id: UUID = UUID(), source: MediaSource, name: String = "Preparing…") {
        self.id = id; self.source = source; self.name = name
        byteCount = 0; state = .queued; attempts = 0
    }
}

/// What a worker tells the queue while it runs one item.
enum UploadEvent: Equatable, Sendable {
    case described(name: String, byteCount: Int64)
    case state(UploadItem.State)
}

typealias UploadEventSink = @Sendable (UploadEvent) -> Void
typealias UploadWorker = @Sendable (MediaSource, UploadOptions, @escaping UploadEventSink) async throws -> UploadOutcome

/// The activity queue: a bounded number of items in flight, per-item progress,
/// cancellation, and retry with backoff.
///
/// Retry deliberately does *not* re-do what `GPMCClient` already handles — that
/// actor refreshes an access token that is near expiry and spends one forced
/// re-auth on a mid-flight 401/403. What is left over, and lives here, is the
/// whole-item retry for transport and 5xx failures, and the hard stop when the
/// credential itself is refused: no other item in the queue can succeed either,
/// so the queue halts and waits for the account to be reconnected.
@MainActor
final class UploadQueue: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    /// Non-nil when the queue stopped itself because the account needs attention.
    @Published private(set) var haltReason: String?
    @Published var options = UploadOptions()

    /// Called once when Google refuses the credential, so the account state can follow.
    var onCredentialRejected: ((Error) -> Void)?

    let maxConcurrent: Int
    let maxAttempts: Int
    private let worker: UploadWorker
    private let sleeper: @Sendable (Double) async -> Void
    private var running: [UUID: Task<Void, Never>] = [:]
    private var userCancelled: Set<UUID> = []
    private var haltCancelled: Set<UUID> = []

    init(worker: @escaping UploadWorker,
         maxConcurrent: Int = 2,
         maxAttempts: Int = 3,
         sleeper: @escaping @Sendable (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.worker = worker
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.sleeper = sleeper
    }

    // MARK: - Aggregates for the UI

    var activeCount: Int { items.filter { !$0.state.isFinished }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var isIdle: Bool { activeCount == 0 }
    var overallFraction: Double {
        let tracked = items.filter { !$0.state.isFinished || $0.state == .done || $0.state == .alreadyBackedUp }
        guard !tracked.isEmpty else { return 0 }
        return tracked.reduce(0) { $0 + ($1.state.fraction ?? 0) } / Double(tracked.count)
    }

    // MARK: - Commands

    func enqueue(_ sources: [MediaSource]) {
        items.append(contentsOf: sources.map { UploadItem(source: $0) })
        pump()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].state.isFinished else { return }
        userCancelled.insert(id)
        if let task = running[id] { task.cancel() } else { items[index].state = .cancelled; userCancelled.remove(id) }
    }

    func cancelAll() {
        for item in items where !item.state.isFinished { cancel(item.id) }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isFinished,
              items[index].state != .done, items[index].state != .alreadyBackedUp else { return }
        items[index].attempts = 0
        items[index].state = .queued
        pump()
    }

    func retryAllFailed() {
        for item in items { if case .failed = item.state { retry(item.id) } }
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    /// Clear the halt after the account has been reconnected; everything that
    /// was stopped mid-flight went back to `queued` and picks up here.
    func resume() {
        haltReason = nil
        pump()
    }

    // MARK: - Scheduling

    private func pump() {
        guard haltReason == nil else { return }
        while running.count < maxConcurrent, let index = items.firstIndex(where: { $0.state == .queued }) {
            start(items[index].id)
        }
    }

    private func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .exporting
        items[index].attempts += 1
        let source = items[index].source
        let options = self.options
        let worker = self.worker
        running[id] = Task { [weak self] in
            var sink: AsyncStream<UploadEvent>.Continuation!
            let stream = AsyncStream<UploadEvent> { sink = $0 }
            let events = sink!
            let drain = Task { @MainActor [weak self] in
                for await event in stream { self?.apply(event, to: id) }
            }
            let outcome: Result<UploadOutcome, Error>
            do { outcome = .success(try await worker(source, options, { events.yield($0) })) }
            catch { outcome = .failure(error) }
            events.finish()
            await drain.value
            self?.finish(id, outcome)
        }
    }

    private func apply(_ event: UploadEvent, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .described(let name, let byteCount):
            items[index].name = name; items[index].byteCount = byteCount
        case .state(let state):
            guard !items[index].state.isFinished else { return }
            items[index].state = state
        }
    }

    private func finish(_ id: UUID, _ outcome: Result<UploadOutcome, Error>) {
        running[id] = nil
        defer { pump() }
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let result):
            items[index].mediaKey = result.mediaKey
            items[index].state = { if case .alreadyBackedUp = result { return .alreadyBackedUp } else { return .done } }()
        case .failure(let error):
            if userCancelled.remove(id) != nil {
                haltCancelled.remove(id); items[index].state = .cancelled; return
            }
            // A cancellation the user did not ask for is the halt below reaching
            // in; put the item back so `resume()` picks it up unchanged.
            if haltCancelled.remove(id) != nil { items[index].state = .queued; return }
            if error is CancellationError { items[index].state = .cancelled; return }
            let gpmc = error as? GPMCError
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let gpmc, gpmc.kind == .credentialRejected || gpmc.kind == .tokenBound {
                items[index].state = .queued
                halt(gpmc)
                return
            }
            let retryable = gpmc?.isRetryable ?? false
            if retryable, items[index].attempts < maxAttempts {
                let attempt = items[index].attempts
                items[index].state = .waitingToRetry(attempt: attempt)
                scheduleRetry(id, after: min(30, pow(2, Double(attempt))))
            } else {
                items[index].state = .failed(reason: reason, retryable: retryable)
            }
        }
    }

    private func halt(_ error: GPMCError) {
        guard haltReason == nil else { return }
        haltReason = error.message
        for (id, task) in running { haltCancelled.insert(id); task.cancel() }
        onCredentialRejected?(error)
    }

    private func scheduleRetry(_ id: UUID, after seconds: Double) {
        let sleeper = self.sleeper
        Task { [weak self] in
            await sleeper(seconds)
            guard let self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            guard case .waitingToRetry = self.items[index].state else { return }
            self.items[index].state = .queued
            self.pump()
        }
    }
}
