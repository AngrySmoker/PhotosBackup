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

private extension MediaSource {
    /// Album scans can contain the same asset through multiple selected albums.
    /// Stable keys keep automatic enqueue linear even for large libraries.
    var queueDeduplicationKey: String? {
        switch self {
        case .asset(let identifier): return "asset:\(identifier)"
        case .file(let url): return "file:\(url.standardizedFileURL.path)"
        case .picked: return nil
        }
    }
}

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
    /// Non-nil while the selected connection policy does not permit uploads.
    @Published private(set) var networkPauseReason: String?
    /// Set when iOS ends a background execution window before the queue drains.
    @Published private(set) var systemPauseReason: String?
    /// A non-fatal warning when the durable queue cannot be read or written.
    @Published private(set) var persistenceWarning: String?
    @Published var options = UploadOptions()

    /// Called once when Google refuses the credential, so the account state can follow.
    var onCredentialRejected: ((Error) -> Void)?

    let maxConcurrent: Int
    let maxAttempts: Int
    private let worker: UploadWorker
    private let sleeper: @Sendable (Double) async -> Void
    private let persistence: UploadQueuePersisting?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var userCancelled: Set<UUID> = []
    private var requeueCancelled: Set<UUID> = []
    private var accountIdentifier: String?
    private var completedSourceKeys: Set<String> = []

    init(worker: @escaping UploadWorker,
         maxConcurrent: Int = 2,
         maxAttempts: Int = 3,
         persistence: UploadQueuePersisting? = nil,
         sleeper: @escaping @Sendable (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.worker = worker
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.persistence = persistence
        self.sleeper = sleeper
    }

    // MARK: - Aggregates for the UI

    var activeCount: Int { items.filter { !$0.state.isFinished }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var isIdle: Bool { activeCount == 0 }
    var pauseReason: String? { haltReason ?? networkPauseReason ?? systemPauseReason }
    var overallFraction: Double {
        let tracked = items.filter { !$0.state.isFinished || $0.state == .done || $0.state == .alreadyBackedUp }
        guard !tracked.isEmpty else { return 0 }
        return tracked.reduce(0) { $0 + ($1.state.fraction ?? 0) } / Double(tracked.count)
    }

    // MARK: - Commands

    @discardableResult
    func enqueue(_ sources: [MediaSource], skippingExisting: Bool = false, limit: Int? = nil) -> [UUID] {
        var accepted: [UploadItem] = []
        var trackedKeys = completedSourceKeys.union(items.compactMap { item -> String? in
            switch item.state {
            case .failed, .cancelled: return nil
            default: return item.source.queueDeduplicationKey
            }
        })
        for source in sources {
            if let limit, accepted.count >= max(0, limit) { break }
            if skippingExisting {
                if let key = source.queueDeduplicationKey {
                    guard trackedKeys.insert(key).inserted else { continue }
                } else {
                    let isAlreadyTracked = items.contains { item in
                        guard item.source == source else { return false }
                        switch item.state {
                        case .failed, .cancelled: return false
                        default: return true
                        }
                    }
                    if isAlreadyTracked || accepted.contains(where: { $0.source == source }) { continue }
                }
            }
            accepted.append(UploadItem(source: source))
        }
        items.append(contentsOf: accepted)
        persist()
        pump()
        return accepted.map(\.id)
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].state.isFinished else { return }
        userCancelled.insert(id)
        if let task = running[id] {
            task.cancel()
        } else {
            items[index].state = .cancelled
            userCancelled.remove(id)
            requeueCancelled.remove(id)
            persist()
        }
    }

    func cancelAll() {
        for item in items where !item.state.isFinished { cancel(item.id) }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isFinished,
              items[index].state != .done, items[index].state != .alreadyBackedUp else { return }
        items[index].attempts = 0
        items[index].state = .queued
        persist()
        pump()
    }

    func retryAllFailed() {
        for item in items { if case .failed = item.state { retry(item.id) } }
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
        persist()
    }

    /// Select and restore the durable queue for the connected account. A queue
    /// is never reused for a different Google account.
    func activateAccount(_ identifier: String?) {
        let next = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = next.flatMap { $0.isEmpty ? nil : $0 }
        guard normalized != accountIdentifier else { return }

        if accountIdentifier != nil { persist() }
        cancelRunningForRequeue()
        accountIdentifier = normalized
        items = []
        completedSourceKeys = []
        haltReason = nil
        systemPauseReason = nil
        persistenceWarning = nil

        guard let normalized, let persistence else { return }
        do {
            guard let snapshot = try persistence.load(),
                  snapshot.version == UploadQueueSnapshot.version,
                  snapshot.accountIdentifier == normalized else {
                persist()
                return
            }
            completedSourceKeys = Set(snapshot.completedSourceKeys)
            items = snapshot.items.map { stored in
                var item = UploadItem(id: stored.id, source: stored.source.mediaSource, name: stored.name)
                item.byteCount = stored.byteCount
                item.attempts = stored.attempts
                if let reason = stored.failureReason {
                    item.state = .failed(reason: reason, retryable: stored.failureRetryable)
                } else {
                    item.state = .queued
                }
                return item
            }
            pump()
        } catch {
            persistenceWarning = "The saved upload queue could not be restored: \(error.localizedDescription)"
        }
    }

    /// Clear the halt after the account has been reconnected; everything that
    /// was stopped mid-flight went back to `queued` and picks up here.
    func resume() {
        haltReason = nil
        pump()
    }

    /// Apply the current user-selected connection policy. Losing an allowed
    /// transport cancels in-flight work and requeues it so no upload can leak
    /// onto cellular after Wi-Fi disappears.
    func setNetworkAccess(allowed: Bool, pauseReason: String? = nil) {
        let nextReason = allowed ? nil : (pauseReason ?? "Waiting for an allowed connection")
        guard networkPauseReason != nextReason else { return }
        networkPauseReason = nextReason
        if allowed { pump() }
        else { cancelRunningForRequeue() }
    }

    /// Called by the background-task expiration handler. Work remains queued
    /// for the next system execution window or foreground launch.
    func suspendForBackgroundExpiration() {
        systemPauseReason = "Waiting for iOS to continue the backup"
        cancelRunningForRequeue()
    }

    func resumeSystemWork() {
        guard systemPauseReason != nil else { return }
        systemPauseReason = nil
        pump()
    }

    /// Wait for all unfinished queue work. Cancellation is how a background
    /// task tells this loop that its execution window has expired.
    func waitUntilSettled() async -> Bool {
        while !isIdle {
            if Task.isCancelled { return false }
            if networkPauseReason != nil || systemPauseReason != nil { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return haltReason == nil
    }

    // MARK: - Scheduling

    private func pump() {
        guard pauseReason == nil else { return }
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
            persist()
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
            if let key = items[index].source.queueDeduplicationKey { completedSourceKeys.insert(key) }
            persist()
        case .failure(let error):
            if userCancelled.remove(id) != nil {
                requeueCancelled.remove(id); items[index].state = .cancelled; persist(); return
            }
            // Policy, credential and background-expiration pauses all cancel
            // in-flight work for requeue. A later pump restarts it unchanged.
            if requeueCancelled.remove(id) != nil { items[index].state = .queued; persist(); return }
            if error is CancellationError { items[index].state = .cancelled; persist(); return }
            let gpmc = error as? GPMCError
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let gpmc, gpmc.kind == .credentialRejected || gpmc.kind == .tokenBound {
                items[index].state = .queued
                persist()
                halt(gpmc)
                return
            }
            let retryable = gpmc?.isRetryable ?? false
            if retryable, items[index].attempts < maxAttempts {
                let attempt = items[index].attempts
                items[index].state = .waitingToRetry(attempt: attempt)
                persist()
                scheduleRetry(id, after: min(30, pow(2, Double(attempt))))
            } else {
                items[index].state = .failed(reason: reason, retryable: retryable)
                persist()
            }
        }
    }

    private func halt(_ error: GPMCError) {
        guard haltReason == nil else { return }
        haltReason = error.message
        cancelRunningForRequeue()
        onCredentialRejected?(error)
    }

    private func cancelRunningForRequeue() {
        for (id, task) in running {
            requeueCancelled.insert(id)
            task.cancel()
        }
    }

    private func scheduleRetry(_ id: UUID, after seconds: Double) {
        let sleeper = self.sleeper
        Task { [weak self] in
            await sleeper(seconds)
            guard let self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            guard case .waitingToRetry = self.items[index].state else { return }
            self.items[index].state = .queued
            self.persist()
            self.pump()
        }
    }

    private func persist() {
        guard let accountIdentifier, let persistence else { return }
        let storedItems = items.compactMap { item -> PersistedUploadItem? in
            guard let source = PersistedMediaSource(item.source) else { return nil }
            switch item.state {
            case .alreadyBackedUp, .done, .cancelled:
                return nil
            case .failed(let reason, let retryable):
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: reason, failureRetryable: retryable)
            default:
                // Working and retry-delay states intentionally restore queued.
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: nil, failureRetryable: false)
            }
        }
        let snapshot = UploadQueueSnapshot(
            version: UploadQueueSnapshot.version,
            accountIdentifier: accountIdentifier,
            items: storedItems,
            completedSourceKeys: completedSourceKeys.sorted()
        )
        do {
            try persistence.save(snapshot)
            persistenceWarning = nil
        } catch {
            persistenceWarning = "Upload progress could not be saved: \(error.localizedDescription)"
        }
    }
}
