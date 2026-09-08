import BackgroundTasks
import Foundation
import OSLog
import UIKit

/// Owns opportunistic automatic-backup runs in both foreground and system
/// background execution windows. iOS decides when a processing request runs;
/// every invocation submits its successor so the work remains recurring.
@MainActor
final class AutomaticBackupCoordinator: ObservableObject {
    static let taskIdentifier = "com.g8row.photosbackup.background-backup"
    private static let logger = Logger(subsystem: "com.g8row.photosbackup", category: "automatic-backup")

    /// How many sources one enqueue pass may append. These bound *memory*, not
    /// how much a window uploads — the queue is durable, so anything a window
    /// cannot finish simply waits for the next one. The old background value of
    /// 25 meant a window that iOS might only grant once a day could never let
    /// the queue saturate, and so could never advance the change token either.
    private static let foregroundBatchLimit = 250
    private static let backgroundBatchLimit = 250

    private let photos: PhotosStack
    private let account: PhotosAccount
    private let queue: UploadQueue
    private let preferences: BackupPreferences
    private let albums: PhotoAlbumStore
    private let network: NetworkPolicyMonitor
    private let libraryChanges: PhotoLibraryChangeTracker

    private var registered = false
    private var ranForegroundBackup = false
    private var isForeground = true
    private var shouldRunAfterActivation = false
    private var backgroundOperation: Task<Void, Never>?
    private var foregroundOperation: Task<Void, Never>?
    private var foregroundRunID: UUID?
#if DEBUG
    @Published private(set) var debugSimulationStatus = "Ready"
    static let lldbSimulationCommand = "e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@\"\(taskIdentifier)\"]"
    /// The run's OSLog output goes to the system log, not to this screen. On a
    /// simulator this streams it; on a device use Console.app and filter by the
    /// same subsystem.
    static let logStreamCommand = "xcrun simctl spawn booted log stream --level debug --predicate 'subsystem == \"com.g8row.photosbackup\"'"
#endif

    init(photos: PhotosStack,
         account: PhotosAccount,
         queue: UploadQueue,
         preferences: BackupPreferences,
         albums: PhotoAlbumStore,
         network: NetworkPolicyMonitor,
         libraryChanges: PhotoLibraryChangeTracker? = nil) {
        self.photos = photos
        self.account = account
        self.queue = queue
        self.preferences = preferences
        self.albums = albums
        self.network = network
        self.libraryChanges = libraryChanges ?? PhotoLibraryChangeTracker()

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // iOS expects an expiration handler promptly, and the hop to the
            // main actor below can be delayed by whatever it is already doing.
            // Install a handler that works before `begin` runs, then let
            // `begin` replace it with one that can also cancel the operation.
            let window = BackgroundWindow()
            task.expirationHandler = { window.expire() }
            Task { @MainActor [weak self] in self?.begin(task, window: window) }
        }
    }

    func start() async {
        isForeground = UIApplication.shared.applicationState == .active
        queue.setICloudDownloadsAllowed(isForeground)
        await photos.start()
        applyNetworkPolicy()
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func networkDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func connectionPreferenceDidChange() {
        applyNetworkPolicy()
        runForegroundBackupIfNeeded()
    }

    func backupConfigurationDidChange() {
        cancelForegroundScan()
        ranForegroundBackup = false
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func accountDidChange() {
        cancelForegroundScan()
        ranForegroundBackup = false
        queue.activateAccount(account.status.email)
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func applicationDidEnterBackground() {
        cancelForegroundScan()
        queue.flushPendingWrites()
        isForeground = false
        queue.setICloudDownloadsAllowed(false)
        shouldRunAfterActivation = true
        updateSchedule()
    }

    func applicationDidBecomeActive() {
        isForeground = true
        queue.setICloudDownloadsAllowed(true)
        queue.resumeSystemWork()
        if shouldRunAfterActivation {
            shouldRunAfterActivation = false
            ranForegroundBackup = false
        }
        runForegroundBackupIfNeeded()
    }

    func applyNetworkPolicy() {
        photos.setCellularUploadsAllowed(preferences.connection == .wifiAndCellular)
        let decision = preferences.connection.decision(for: network.status)
        queue.setNetworkAccess(allowed: decision.allowsUploads, pauseReason: decision.pauseReason)
    }

    func updateSchedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard registered, shouldSchedule else { return }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Self.logger.info("Scheduled the next automatic-backup processing request")
        } catch {
            Self.logger.error("Could not schedule automatic backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Why automatic backup cannot run, in the user's terms, or nil when it can.
    /// One source of truth so a refused run can say which condition stopped it
    /// instead of reporting a bare failure.
    var scheduleBlocker: String? {
        if !preferences.completedOnboarding { return "Onboarding is not finished" }
        if !preferences.automaticBackup { return "Automatic Backup is turned off" }
        if preferences.selectedAlbumIDs.isEmpty { return "No albums are selected" }
        if !account.status.isUsable { return "No Google account is connected" }
        return nil
    }

    private var shouldSchedule: Bool { scheduleBlocker == nil }

    private func runForegroundBackupIfNeeded() {
        guard isForeground,
              !ranForegroundBackup,
              shouldSchedule,
              !queue.isUserPaused,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return }

        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.albums.refresh()
            if self.albums.canRead, !Task.isCancelled {
                let sources = await self.albums.sources(for: self.preferences.selectedAlbumIDs)
                if !Task.isCancelled { await self.performForegroundBackup(sources) }
            } else {
                // Access was refused or not decided yet. Release the once-per
                // foreground latch so granting it later still starts a scan.
                self.ranForegroundBackup = false
            }
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
        }
    }

    /// Keep the in-memory queue bounded without stopping an initial backup after
    /// its first page. Completed and failed source keys make each rescan cheap
    /// and ensure the loop eventually reaches every selected asset.
    private func performForegroundBackup(_ sources: [MediaSource]) async {
        // Same reasoning as the background window: earlier transport failures
        // are invisible to the scan and nothing else releases them.
        queue.retryRetryableFailures()
        while isForeground, !Task.isCancelled, account.status.isUsable, shouldSchedule, !isPausedForAnyReason {
            let accepted = queue.enqueue(sources, skippingExisting: true, limit: Self.foregroundBatchLimit)
            if accepted.isEmpty { return }
            while queue.activeCount > 0 {
                // A pause the queue is honouring must end the loop too,
                // otherwise this polls every 200 ms for as long as the user
                // waits for Wi-Fi or leaves the backup paused.
                if Task.isCancelled || !isForeground || !account.status.isUsable || !shouldSchedule
                    || queue.haltReason != nil || isPausedForAnyReason { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Any condition that stops the queue starting new work. Polling past one
    /// of these makes no progress and only keeps the main actor awake.
    private var isPausedForAnyReason: Bool {
        queue.isUserPaused || queue.networkPauseReason != nil || queue.systemPauseReason != nil
    }

    /// The result of a manual "Back Up Now" or "Re-check Backups", so the UI can
    /// say what happened instead of leaving a button that appears to do nothing.
    enum ManualRunOutcome: Equatable {
        case noLibraryAccess
        case noAlbumsSelected
        case nothingToDo
        case started(count: Int)
        case rechecking(count: Int)
    }

    /// "Back Up Now". Runs the same bounded, paged loop the automatic scan uses
    /// so a large library cannot be poured into the queue in one go.
    func backUpSelectedAlbumsNow() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return .noAlbumsSelected }
        await albums.refresh()
        guard albums.canRead else { return .noLibraryAccess }
        let sources = await albums.sources(for: preferences.selectedAlbumIDs)
        let accepted = queue.enqueue(sources, skippingExisting: true, limit: Self.foregroundBatchLimit)
        guard !accepted.isEmpty else { return .nothingToDo }
        startPagedRun(sources)
        return .started(count: accepted.count)
    }

    /// "Re-check Backups". Forgets remembered completions for the selection and
    /// re-enqueues it; the worker's hash lookup settles anything still in the
    /// cloud without re-uploading it.
    func reverifySelectedAlbums() async -> ManualRunOutcome {
        guard !preferences.selectedAlbumIDs.isEmpty else { return .noAlbumsSelected }
        await albums.refresh()
        guard albums.canRead else { return .noLibraryAccess }
        let sources = await albums.sources(for: preferences.selectedAlbumIDs)
        guard !sources.isEmpty else { return .nothingToDo }
        let result = queue.reverify(sources, limit: Self.foregroundBatchLimit)
        guard result.enqueued > 0 else { return .nothingToDo }
        startPagedRun(sources)
        return .rechecking(count: result.enqueued)
    }

    /// Take over the foreground paging loop for a manually started run, so the
    /// remaining pages follow without the user tapping again.
    private func startPagedRun(_ sources: [MediaSource]) {
        cancelForegroundScan()
        ranForegroundBackup = true
        let runID = UUID()
        foregroundRunID = runID
        foregroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performForegroundBackup(sources)
            if self.foregroundRunID == runID {
                self.foregroundOperation = nil
                self.foregroundRunID = nil
            }
        }
    }

    private func cancelForegroundScan() {
        foregroundOperation?.cancel()
        foregroundOperation = nil
        foregroundRunID = nil
    }

    private func begin(_ task: BGProcessingTask, window: BackgroundWindow) {
        Self.logger.info("Beginning an iOS background-processing window")
        isForeground = false
        updateSchedule()
        queue.setICloudDownloadsAllowed(false)
        queue.resumeSystemWork()
        backgroundOperation?.cancel()

        let operation = Task { @MainActor [weak self, weak task] in
            guard let self else {
                task?.setTaskCompleted(success: false)
                return
            }
            let report = await self.performBackgroundBackup()
            task?.expirationHandler = nil
            task?.setTaskCompleted(success: report.success)
            Self.logger.info("Background-processing window finished; success=\(report.success)")
            self.backgroundOperation = nil
        }
        backgroundOperation = operation
        let expire: @Sendable () -> Void = { [weak self] in
            Self.logger.notice("iOS expired the background-processing window; requeuing unfinished uploads")
            operation.cancel()
            Task { @MainActor [weak self] in self?.queue.suspendForBackgroundExpiration() }
        }
        task.expirationHandler = expire
        // iOS may already have expired the window while this hop was queued.
        window.adopt(expire)
    }

    /// The outcome of one window, with the reason attached. `success` is what
    /// iOS is told; `summary` is what a human reads in Diagnostics and the log.
    struct BackgroundRunReport {
        let success: Bool
        let summary: String
    }

    private func performBackgroundBackup() async -> BackgroundRunReport {
        await photos.start()
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()

        // A user pause is durable and must not be bypassed by a scheduled run.
        guard !queue.isUserPaused else {
            return finish(.init(success: true, summary: "Paused by you — no work started"))
        }

        if let blocker = scheduleBlocker {
            return finish(.init(success: false, summary: blocker))
        }
        let decision = preferences.connection.decision(for: network.status)
        guard decision.allowsUploads else {
            return finish(.init(success: false,
                                summary: decision.pauseReason ?? "The connection policy does not allow uploads"))
        }

        await albums.refresh()
        guard albums.canRead else {
            return finish(.init(success: false, summary: "No photo library access"))
        }
        // Release earlier transport/5xx failures before scanning. They are
        // invisible to the scan (the dedup treats a failed row as a durable
        // handle), so without this a network blip parks those items forever.
        let released = queue.retryRetryableFailures()
        let failuresBefore = queue.failedCount
        let scan = libraryChanges.scan(albums: albums,
                                       selectedAlbumIDs: preferences.selectedAlbumIDs,
                                       accountIdentifier: account.status.email)
        // An edited asset already has a completion recorded against its
        // identifier, so the dedup below would drop it. Release those first;
        // the worker's hash lookup still short-circuits anything whose bytes
        // did not actually change.
        if !scan.editedSources.isEmpty {
            queue.forgetCompletedSources(for: scan.editedSources)
        }
        let outcome = queue.enqueueReportingLimit(scan.sources, skippingExisting: true,
                                                  limit: Self.backgroundBatchLimit)
        // Advance the change token once every source in this scan has been
        // durably handed to the queue — accepted now, or already tracked. Only
        // a batch the limit cut short leaves sources unexamined.
        if !outcome.reachedLimit, queue.persistenceWarning == nil { libraryChanges.commit(scan) }

        let backedUpBefore = queue.completedSourceCount
        let settled = await queue.waitUntilSettled()
        let uploaded = max(0, queue.completedSourceCount - backedUpBefore)
        let newFailures = queue.failedCount - failuresBefore
        var parts: [String] = []
        if released > 0 { parts.append("retried \(released) earlier failure\(released == 1 ? "" : "s")") }
        parts.append("enqueued \(outcome.accepted.count)")
        parts.append("backed up \(uploaded)")
        // Report the standing failure count, not just this run's delta: a queue
        // that is entirely stuck reads as "nothing happened" otherwise.
        if queue.failedCount > 0 {
            parts.append(newFailures > 0
                ? "\(queue.failedCount) failed (\(newFailures) new)"
                : "\(queue.failedCount) still failing")
        }
        if queue.deferredForICloudCount > 0 {
            parts.append("\(queue.deferredForICloudCount) waiting on iCloud")
        }
        if outcome.reachedLimit { parts.append("more to scan next window") }
        // Say why zero, rather than leaving the reader to guess.
        if outcome.accepted.isEmpty, uploaded == 0, queue.failedCount == 0 {
            parts.append(scan.sources.isEmpty
                ? "no library changes since the last scan"
                : "everything in the selection is already backed up")
        }

        if let halt = queue.haltReason {
            return finish(.init(success: false, summary: "Stopped: \(halt)"))
        }
        if !settled {
            // Expiration or a policy pause cancels the wait, but the work
            // remains durably queued for the next window. Report success
            // unless the credential halted or new failures appeared,
            // otherwise iOS backs off a window that did everything it could.
            let reason = queue.pauseReason ?? "ran out of time"
            parts.append("deferred — \(reason)")
            return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
        }
        return finish(.init(success: newFailures == 0, summary: parts.joined(separator: " · ")))
    }

    private func finish(_ report: BackgroundRunReport) -> BackgroundRunReport {
        if report.success {
            Self.logger.info("Automatic backup run: \(report.summary, privacy: .public)")
        } else {
            Self.logger.notice("Automatic backup run did not complete: \(report.summary, privacy: .public)")
        }
        return report
    }

    /// Called from the background URL-session delegate before iOS receives its
    /// relaunch completion handler. It restores the queue and lets completed
    /// PUT receipts reach the small commit RPC.
    func handleBackgroundURLSessionEvents() async {
        isForeground = UIApplication.shared.applicationState == .active
        if !isForeground {
            // Filter before restoration so `activateAccount`'s internal pump
            // cannot start fresh exports, and pause network so nothing pumps
            // before the real policy is applied below.
            queue.noteBackgroundTransferCompletionsPending()
            queue.setNetworkAccess(allowed: false, pauseReason: "Restoring background transfers")
        }
        await photos.start()
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()
        isForeground = UIApplication.shared.applicationState == .active
        queue.setICloudDownloadsAllowed(isForeground)
        if isForeground { queue.resumeSystemWork() }
        else { queue.resumeBackgroundTransferCompletions() }
        await queue.waitUntilBackgroundTransfersHandled()
        isForeground = UIApplication.shared.applicationState == .active
        if isForeground { queue.resumeSystemWork() }
        else { queue.finishBackgroundTransferCompletions() }
    }

#if DEBUG
    func simulateRun() {
        guard backgroundOperation == nil else { return }
        debugSimulationStatus = "Running…"
        queue.setICloudDownloadsAllowed(false)
        backgroundOperation = Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.performBackgroundBackup()
            self.debugSimulationStatus = report.summary
            if self.isForeground { self.queue.setICloudDownloadsAllowed(true) }
            self.backgroundOperation = nil
        }
    }
#endif
}

/// Bridges the gap between a `BGProcessingTask` arriving on a system queue and
/// the coordinator taking it over on the main actor. An expiration that lands
/// inside that gap is remembered and replayed to the real handler.
final class BackgroundWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var handler: (@Sendable () -> Void)?

    func expire() {
        lock.lock()
        expired = true
        let handler = self.handler
        lock.unlock()
        handler?()
    }

    func adopt(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        let alreadyExpired = expired
        lock.unlock()
        if alreadyExpired { handler() }
    }
}
