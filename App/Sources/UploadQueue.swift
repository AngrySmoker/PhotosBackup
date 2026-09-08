import Foundation
import SwiftUI

struct UploadOptions: Equatable, Sendable {
    /// Upload against the account's storage quota rather than as a device backup.
    var useQuota = false
    /// Ask Google to re-encode ("Storage saver") instead of keeping the original.
    var storageSaver = false
    /// Background processing must never spend its short CPU window downloading
    /// a cloud-only PhotoKit resource. Foreground work may opt back in.
    var allowsICloudDownload = true
}

/// One row of the activity list.
struct UploadItem: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case queued
        case waitingToRetry(attempt: Int)
        case waitingForICloud
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
            case .waitingForICloud: return "Will download from iCloud when you open the app"
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
    var checkpoint: UploadCheckpoint?

    init(id: UUID = UUID(), source: MediaSource, name: String = "Preparing…") {
        self.id = id; self.source = source; self.name = name
        byteCount = 0; state = .queued; attempts = 0
    }
}

/// What a worker tells the queue while it runs one item.
enum UploadEvent: Equatable, Sendable {
    case described(name: String, byteCount: Int64)
    case state(UploadItem.State)
    case checkpoint(UploadCheckpoint?)
}

typealias UploadEventSink = @Sendable (UploadEvent) async -> Void
typealias UploadWorker = @Sendable (UUID, MediaSource, UploadCheckpoint?, UploadOptions, @escaping UploadEventSink) async throws -> UploadOutcome
typealias UploadCheckpointCleaner = @Sendable (UUID, UploadCheckpoint) async -> Void

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
    /// A durable user pause. Current uploads finish; new uploads wait.
    @Published private(set) var isUserPaused = false
    /// A non-fatal warning when the durable queue cannot be read or written.
    @Published private(set) var persistenceWarning: String?
    @Published var options = UploadOptions()

    /// Called once when Google refuses the credential, so the account state can follow.
    var onCredentialRejected: ((Error) -> Void)?
    /// Called exactly once per item that reaches a backed-up state, including
    /// during a background window where no view is observing the queue.
    var onItemBackedUp: (() -> Void)?

    let maxConcurrent: Int
    let maxAttempts: Int
    private let worker: UploadWorker
    private let sleeper: @Sendable (Double) async -> Void
    private let persistence: UploadQueuePersisting?
    private let checkpointCleaner: UploadCheckpointCleaner?
    private var running: [UUID: Task<Void, Never>] = [:]
    private var userCancelled: Set<UUID> = []
    private var requeueCancelled: Set<UUID> = []
    private var accountIdentifier: String?
    private var completedSourceKeys: Set<String> = []
    private var completionLedgerHealthy = true
    private var drainsBackgroundCompletionsOnly = false
    /// Set while a `cancelAll` is settling, so the rows it cancels are dropped
    /// instead of persisted as durable "skip this source" markers.
    private var discardsCancelledRows = false
    private var persistScheduled = false

    init(worker: @escaping UploadWorker,
         maxConcurrent: Int = 2,
         maxAttempts: Int = 3,
         persistence: UploadQueuePersisting? = nil,
         checkpointCleaner: UploadCheckpointCleaner? = nil,
         sleeper: @escaping @Sendable (Double) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.worker = worker
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxAttempts = max(1, maxAttempts)
        self.persistence = persistence
        self.checkpointCleaner = checkpointCleaner
        self.sleeper = sleeper
    }

    // MARK: - Aggregates for the UI

    var activeCount: Int { items.filter { !$0.state.isFinished }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    /// Items held back because their bytes are only in iCloud. They are not
    /// stalled — they resume when the app is foregrounded — but they do sit in
    /// `activeCount`, so the UI has to be able to explain them.
    var deferredForICloudCount: Int { items.filter { $0.state == .waitingForICloud }.count }
    var isIdle: Bool { activeCount == 0 }
    var pauseReason: String? {
        haltReason
            ?? (isUserPaused ? "You paused backup. Tap Resume to continue." : nil)
            ?? networkPauseReason
            ?? systemPauseReason
    }
    var retainedStagingURLs: Set<URL> { Set(items.compactMap { $0.checkpoint?.fileURL }) }
    var overallFraction: Double {
        let tracked = items.filter { !$0.state.isFinished || $0.state == .done || $0.state == .alreadyBackedUp }
        guard !tracked.isEmpty else { return 0 }
        return tracked.reduce(0) { $0 + ($1.state.fraction ?? 0) } / Double(tracked.count)
    }

    // MARK: - Commands

    /// What one `enqueue` call did. `reachedLimit` is the part callers with a
    /// change token care about: when the limit cut the batch short, some
    /// sources were never looked at, so the caller must not record the scan as
    /// fully handled.
    struct EnqueueOutcome {
        let accepted: [UUID]
        let reachedLimit: Bool
    }

    @discardableResult
    func enqueue(_ sources: [MediaSource], skippingExisting: Bool = false, limit: Int? = nil) -> [UUID] {
        enqueueReportingLimit(sources, skippingExisting: skippingExisting, limit: limit).accepted
    }

    @discardableResult
    func enqueueReportingLimit(_ sources: [MediaSource],
                               skippingExisting: Bool = false,
                               limit: Int? = nil) -> EnqueueOutcome {
        var reachedLimit = false
        var accepted: [UploadItem] = []
        // A failed row is already the durable retry handle for its source, and
        // so is a cancelled one: automatic rescans must not append another
        // identical row on every window, and a cancellation the user made
        // deliberately must not silently undo itself on the next scan. Both are
        // released by Retry or Clear Finished in the Activity UI.
        var trackedKeys = completedSourceKeys.union(items.compactMap(\.source.queueDeduplicationKey))
        for source in sources {
            if let limit, accepted.count >= max(0, limit) {
                reachedLimit = true
                break
            }
            if skippingExisting {
                if let key = source.queueDeduplicationKey {
                    guard trackedKeys.insert(key).inserted else { continue }
                } else {
                    let isAlreadyTracked = items.contains { $0.source == source }
                    if isAlreadyTracked || accepted.contains(where: { $0.source == source }) { continue }
                }
            }
            accepted.append(UploadItem(source: source))
        }
        items.append(contentsOf: accepted)
        persistNow()
        pump()
        return EnqueueOutcome(accepted: accepted.map(\.id), reachedLimit: reachedLimit)
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
            cleanCheckpoint(for: index)
            persistNow()
        }
    }

    /// Stop everything and discard the queue. Unlike a single-row cancel, the
    /// resulting rows are dropped rather than kept as durable "don't retry this"
    /// markers — Stop means start over, so a later rescan must be free to pick
    /// these sources up again.
    func cancelAll() {
        isUserPaused = false
        discardsCancelledRows = true
        for item in items where !item.state.isFinished { cancel(item.id) }
        items.removeAll { $0.state == .cancelled }
        persistNow()
    }

    /// Stop scheduling new work without throwing away queue state or staged
    /// files. The pause is durable: it survives the queue draining and a
    /// relaunch, and only an explicit resume or stop clears it. Anything else
    /// would let an automatic rescan quietly restart work the user paused.
    func pauseAfterCurrentUploads() {
        guard !isUserPaused else { return }
        isUserPaused = true
        persistNow()
    }

    func resumeUserPausedUploads() {
        guard isUserPaused else { return }
        isUserPaused = false
        persistNow()
        pump()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isFinished,
              items[index].state != .done, items[index].state != .alreadyBackedUp else { return }
        items[index].attempts = 0
        items[index].state = .queued
        persistNow()
        pump()
    }

    func retryAllFailed() {
        for item in items { if case .failed = item.state { retry(item.id) } }
    }

    func clearFinished() {
        items.removeAll { $0.state.isFinished }
        persistNow()
    }

    /// Number of sources the queue considers already backed up. Used by the
    /// Settings verify action to explain what will be re-checked.
    var completedSourceCount: Int { completedSourceKeys.count }

    /// A snapshot test for "is this library asset already backed up", safe to
    /// hand to a background task computing per-album progress.
    func backedUpAssetLookup() -> @Sendable (String) -> Bool {
        let keys = completedSourceKeys
        return { identifier in keys.contains("asset:\(identifier)") }
    }

    /// Forget remembered completions so the next enqueue re-checks them against
    /// Google (hash lookup) and re-uploads anything deleted in the cloud.
    /// Finished rows for the same sources are removed as well, otherwise the
    /// in-memory dedup in `enqueue(skippingExisting:)` would skip them again.
    /// Returns the number of sources forgotten.
    @discardableResult
    func forgetCompletedSources(for sources: [MediaSource]) -> Int {
        let keys = Set(sources.compactMap(\.queueDeduplicationKey)).intersection(completedSourceKeys)
        guard !keys.isEmpty else { return 0 }
        completedSourceKeys.subtract(keys)
        items.removeAll { item in
            guard item.state.isFinished,
                  let key = item.source.queueDeduplicationKey else { return false }
            return keys.contains(key)
        }
        if let accountIdentifier, let persistence {
            do {
                try persistence.removeCompletedSourceKeys(keys, for: accountIdentifier)
                if completionLedgerHealthy { persistenceWarning = nil }
            } catch {
                completionLedgerHealthy = false
                persistenceWarning = "Upload completion could not be saved: \(error.localizedDescription)"
            }
        }
        persistNow()
        return keys.count
    }

    /// Forget + re-enqueue in one step for Settings. The worker's hash lookup
    /// short-circuits items still in the cloud to `alreadyBackedUp`; only
    /// genuinely missing bytes are uploaded again.
    /// Returns `(forgotten, enqueued)`.
    @discardableResult
    func reverify(_ sources: [MediaSource], limit: Int? = nil) -> (forgotten: Int, enqueued: Int) {
        let forgotten = forgetCompletedSources(for: sources)
        let enqueued = enqueue(sources, skippingExisting: true, limit: limit).count
        return (forgotten, enqueued)
    }

    /// Select and restore the durable queue for the connected account. A queue
    /// is never reused for a different Google account.
    func activateAccount(_ identifier: String?) {
        let next = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = next.flatMap { $0.isEmpty ? nil : $0 }
        guard normalized != accountIdentifier else { return }

        if accountIdentifier != nil {
            persistNow()
            for index in items.indices { cleanCheckpoint(for: index) }
            for task in running.values { task.cancel() }
        }
        accountIdentifier = normalized
        items = []
        completedSourceKeys = []
        completionLedgerHealthy = true
        haltReason = nil
        systemPauseReason = nil
        isUserPaused = false
        persistenceWarning = nil

        guard let normalized, let persistence else { return }
        do {
            let ledgerKeys = try persistence.loadCompletedSourceKeys(for: normalized)
            guard let snapshot = try persistence.load(),
                  snapshot.version == UploadQueueSnapshot.version,
                  snapshot.accountIdentifier == normalized else {
                completedSourceKeys = Set(ledgerKeys)
                persistNow()
                return
            }
            if persistence.storesCompletionLedgerSeparately {
                // One batched append. Per-key writes here meant one file-handle
                // open and close for every photo the library had ever backed up.
                do { try persistence.recordCompletedSourceKeys(snapshot.completedSourceKeys, for: normalized) }
                catch { completionLedgerHealthy = false }
            }
            completedSourceKeys = Set(snapshot.completedSourceKeys)
            completedSourceKeys.formUnion(ledgerKeys)
            isUserPaused = snapshot.isUserPaused ?? false
            items = snapshot.items.compactMap { stored in
                if let key = stored.source.mediaSource.queueDeduplicationKey,
                   completedSourceKeys.contains(key) { return nil }
                var item = UploadItem(id: stored.id, source: stored.source.mediaSource, name: stored.name)
                item.byteCount = stored.byteCount
                item.attempts = stored.attempts
                item.checkpoint = stored.checkpoint
                if stored.cancelled == true {
                    item.state = .cancelled
                } else if let reason = stored.failureReason {
                    item.state = .failed(reason: reason, retryable: stored.failureRetryable)
                } else {
                    item.state = .queued
                }
                return item
            }
            if persistence.storesCompletionLedgerSeparately,
               !snapshot.completedSourceKeys.isEmpty { persistNow() }
            pump()
        } catch {
            persistenceWarning = "The saved upload queue could not be restored: \(error.localizedDescription)"
        }
    }

    /// Write any coalesced snapshot immediately. Called when the app is about
    /// to be suspended, where the next main-actor turn may never come.
    func flushPendingWrites() {
        guard persistScheduled else { return }
        persistNow()
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
        // A background transfer keeps the `allowsCellularAccess` it was created
        // with, so iOS will happily finish it over cellular after the policy
        // says otherwise. Losing an allowed transport therefore has to cancel
        // those too — unlike a background-window expiry, which leaves them
        // running on purpose. The staged file survives, so a retry only repeats
        // the hash and the upload-URL request.
        else { cancelRunningForRequeue(includingBackgroundTransfers: true) }
    }

    /// Called by the background-task expiration handler. Work remains queued
    /// for the next system execution window or foreground launch.
    func suspendForBackgroundExpiration() {
        systemPauseReason = "Paused until iOS gives the app more time"
        cancelRunningForRequeue()
        flushPendingWrites()
    }

    func resumeSystemWork() {
        drainsBackgroundCompletionsOnly = false
        systemPauseReason = nil
        pump()
    }

    /// A background-URLSession wake is for consuming transfer results, not for
    /// starting a fresh library export. Set this before queue restoration.
    /// Prefer `noteBackgroundTransferCompletionsPending()` before restoration
    /// (sets the filter without pumping an empty queue), then call this after
    /// the queue is restored and policy applied to start the drain.
    func resumeBackgroundTransferCompletions() {
        drainsBackgroundCompletionsOnly = true
        systemPauseReason = nil
        pump()
    }

    /// Mark that a background-URLSession wake is pending without starting work
    /// yet. Call this before `activateAccount` so its internal pump already
    /// runs in drains-only mode instead of starting fresh exports.
    func noteBackgroundTransferCompletionsPending() {
        drainsBackgroundCompletionsOnly = true
        systemPauseReason = nil
    }

    func finishBackgroundTransferCompletions() {
        drainsBackgroundCompletionsOnly = false
        suspendForBackgroundExpiration()
    }

    func setICloudDownloadsAllowed(_ allowed: Bool) {
        guard options.allowsICloudDownload != allowed else { return }
        options.allowsICloudDownload = allowed
        if allowed {
            for index in items.indices where items[index].state == .waitingForICloud {
                items[index].state = .queued
            }
            persist()
            pump()
        } else {
            cancelRunningForRequeue()
        }
    }

    /// Wait for all unfinished queue work. Cancellation is how a background
    /// task tells this loop that its execution window has expired.
    func waitUntilSettled() async -> Bool {
        while !isIdle {
            if Task.isCancelled { return false }
            if networkPauseReason != nil || systemPauseReason != nil { return false }
            if isUserPaused && running.isEmpty { return false }
            if running.isEmpty && items.allSatisfy({ $0.state.isFinished || $0.state == .waitingForICloud }) {
                return haltReason == nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return haltReason == nil
    }

    /// Used by the app delegate relaunch path. Do not hold iOS's completion
    /// handler for unrelated queued work; only wait until received PUT results
    /// have either committed or been durably retained. The deadline leaves
    /// margin for iOS's ~30s relaunch window while covering an auth refresh
    /// plus the small commit RPC.
    func waitUntilBackgroundTransfersHandled() async {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, items.contains(where: { item in
            guard let prepared = item.checkpoint?.prepared else { return false }
            return prepared.receipt != nil || (running[item.id] != nil && item.state.isWorking)
        }) {
            if networkPauseReason != nil || systemPauseReason != nil { return }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Scheduling

    private func pump() {
        guard haltReason == nil, networkPauseReason == nil, systemPauseReason == nil else { return }
        while running.count < maxConcurrent, let index = items.firstIndex(where: {
            guard $0.state == .queued else { return false }
            let ownsBackgroundTransfer = $0.checkpoint?.isBackgroundTransfer == true
            if drainsBackgroundCompletionsOnly { return ownsBackgroundTransfer }
            if isUserPaused { return ownsBackgroundTransfer }
            return true
        }) {
            start(items[index].id)
        }
    }

    private func start(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .exporting
        items[index].attempts += 1
        let source = items[index].source
        let checkpoint = items[index].checkpoint
        let options = self.options
        let worker = self.worker
        running[id] = Task { [weak self] in
            let outcome: Result<UploadOutcome, Error>
            do {
                outcome = .success(try await worker(id, source, checkpoint, options) { [weak self] event in
                    await self?.apply(event, to: id)
                })
            }
            catch { outcome = .failure(error) }
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
        case .checkpoint(let checkpoint):
            items[index].checkpoint = checkpoint
            // The durable hand-off to the background transfer: this must be on
            // disk before the worker proceeds, not on the next turn.
            persistNow()
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
            items[index].checkpoint = nil
            recordCompletion(for: items[index])
            persist()
            onItemBackedUp?()
        case .failure(let error):
            if userCancelled.remove(id) != nil {
                requeueCancelled.remove(id)
                items[index].state = .cancelled
                cleanCheckpoint(for: index)
                if discardsCancelledRows {
                    items.remove(at: index)
                    if userCancelled.isEmpty { discardsCancelledRows = false }
                }
                persist()
                return
            }
            // Policy, credential and background-expiration pauses all cancel
            // in-flight work for requeue. A later pump restarts it unchanged.
            if requeueCancelled.remove(id) != nil { items[index].state = .queued; persist(); return }
            if error is CancellationError {
                items[index].state = .cancelled; cleanCheckpoint(for: index); persist(); return
            }
            if error as? MediaExporter.Failure == .iCloudDownloadRequired {
                items[index].attempts = max(0, items[index].attempts - 1)
                items[index].state = .waitingForICloud
                persist()
                return
            }
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
                cleanCheckpoint(for: index)
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

    private func cancelRunningForRequeue(includingBackgroundTransfers: Bool = false) {
        for (id, task) in running {
            if !includingBackgroundTransfers,
               let index = items.firstIndex(where: { $0.id == id }),
               items[index].checkpoint?.isBackgroundTransfer == true {
                continue
            }
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

    /// Coalesce the snapshot write. `persist()` is called from every queue
    /// event — described, each checkpoint, each finish — and each call encodes
    /// the whole items array. Batching to one write per main-actor turn keeps
    /// the durability guarantee (nothing yields between the mutation and the
    /// flush) while collapsing the five or six writes an item used to cost.
    private func persist() {
        guard persistence != nil, accountIdentifier != nil else { return }
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            guard let self, self.persistScheduled else { return }
            self.persistScheduled = false
            self.persistNow()
        }
    }

    /// Write immediately. Used where a later flush would be too late: the
    /// checkpoint hand-off before a background PUT starts, and anything that
    /// runs as the process is about to be suspended.
    private func persistNow() {
        persistScheduled = false
        guard let accountIdentifier, let persistence else { return }
        let storedItems = items.compactMap { item -> PersistedUploadItem? in
            guard let source = PersistedMediaSource(item.source)
                    ?? item.checkpoint.map({ .file($0.filePath) }) else { return nil }
            switch item.state {
            case .alreadyBackedUp, .done:
                return nil
            case .cancelled:
                // Kept so a deliberate cancellation is not silently undone by
                // the next automatic scan. Cleared by Retry or Clear Finished.
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: nil, failureRetryable: false,
                                           checkpoint: nil, cancelled: true)
            case .failed(let reason, let retryable):
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: reason, failureRetryable: retryable,
                                           checkpoint: item.checkpoint)
            default:
                // Working and retry-delay states intentionally restore queued.
                return PersistedUploadItem(id: item.id, source: source, name: item.name,
                                           byteCount: item.byteCount, attempts: item.attempts,
                                           failureReason: nil, failureRetryable: false,
                                           checkpoint: item.checkpoint)
            }
        }
        let snapshot = UploadQueueSnapshot(
            version: UploadQueueSnapshot.version,
            accountIdentifier: accountIdentifier,
            items: storedItems,
            completedSourceKeys: persistence.storesCompletionLedgerSeparately && completionLedgerHealthy
                ? [] : Array(completedSourceKeys),
            isUserPaused: isUserPaused
        )
        do {
            try persistence.save(snapshot)
            if completionLedgerHealthy { persistenceWarning = nil }
        } catch {
            persistenceWarning = "Upload progress could not be saved: \(error.localizedDescription)"
        }
    }

    private func recordCompletion(for item: UploadItem) {
        guard let accountIdentifier, let persistence,
              let key = item.source.queueDeduplicationKey,
              persistence.storesCompletionLedgerSeparately else { return }
        do {
            try persistence.recordCompletedSourceKey(key, for: accountIdentifier)
        } catch {
            completionLedgerHealthy = false
            persistenceWarning = "Upload completion could not be saved: \(error.localizedDescription)"
        }
    }

    private func cleanCheckpoint(for index: Int) {
        guard let checkpoint = items[index].checkpoint else { return }
        let id = items[index].id
        items[index].checkpoint = nil
        guard let checkpointCleaner else { return }
        Task { await checkpointCleaner(id, checkpoint) }
    }
}
