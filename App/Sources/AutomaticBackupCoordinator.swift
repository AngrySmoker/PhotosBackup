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
            Task { @MainActor [weak self] in self?.begin(task) }
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

    private var shouldSchedule: Bool {
        preferences.completedOnboarding
            && preferences.automaticBackup
            && !preferences.selectedAlbumIDs.isEmpty
            && account.status.isUsable
    }

    private func runForegroundBackupIfNeeded() {
        guard isForeground,
              !ranForegroundBackup,
              shouldSchedule,
              !queue.isUserPaused,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return }

        albums.refresh()
        guard albums.canRead else { return }
        ranForegroundBackup = true
        let sources = albums.sources(for: preferences.selectedAlbumIDs)
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

    /// Keep the in-memory queue bounded without stopping an initial backup after
    /// its first page. Completed and failed source keys make each rescan cheap
    /// and ensure the loop eventually reaches every selected asset.
    private func performForegroundBackup(_ sources: [MediaSource]) async {
        while isForeground, !Task.isCancelled, account.status.isUsable, shouldSchedule {
            let accepted = queue.enqueue(sources, skippingExisting: true, limit: 250)
            if accepted.isEmpty { return }
            while queue.activeCount > 0 {
                if Task.isCancelled || !isForeground || !account.status.isUsable || !shouldSchedule
                    || queue.haltReason != nil { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func cancelForegroundScan() {
        foregroundOperation?.cancel()
        foregroundOperation = nil
        foregroundRunID = nil
    }

    private func begin(_ task: BGProcessingTask) {
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
            let success = await self.performBackgroundBackup()
            task?.expirationHandler = nil
            task?.setTaskCompleted(success: success)
            Self.logger.info("Background-processing window finished; success=\(success)")
            self.backgroundOperation = nil
        }
        backgroundOperation = operation
        task.expirationHandler = { [weak self] in
            Self.logger.notice("iOS expired the background-processing window; requeuing unfinished uploads")
            operation.cancel()
            Task { @MainActor [weak self] in self?.queue.suspendForBackgroundExpiration() }
        }
    }

    private func performBackgroundBackup() async -> Bool {
        await photos.start()
        _ = await network.waitForInitialStatus()
        applyNetworkPolicy()

        // A user pause is durable and must not be bypassed by a scheduled run.
        guard !queue.isUserPaused else { return true }

        guard shouldSchedule,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return false }

        albums.refresh()
        guard albums.canRead else { return false }
        let failuresBefore = queue.failedCount
        let scan = libraryChanges.scan(albums: albums,
                                       selectedAlbumIDs: preferences.selectedAlbumIDs,
                                       accountIdentifier: account.status.email)
        let accepted = queue.enqueue(scan.sources, skippingExisting: true, limit: 25)
        // Do not advance past a large import until repeated bounded runs have
        // durably handed every changed asset to the queue.
        if accepted.isEmpty, queue.persistenceWarning == nil { libraryChanges.commit(scan) }
        let settled = await queue.waitUntilSettled()
        if !settled {
            // Expiration or a policy pause cancels the wait, but the work
            // remains durably queued for the next window. Report success
            // unless the credential halted or new failures appeared,
            // otherwise iOS backs off a window that did everything it could.
            if queue.haltReason == nil && queue.failedCount == failuresBefore { return true }
            return false
        }
        return queue.failedCount == failuresBefore
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
            let success = await self.performBackgroundBackup()
            self.debugSimulationStatus = success ? "Finished successfully" : "Finished with deferred or failed work"
            if self.isForeground { self.queue.setICloudDownloadsAllowed(true) }
            self.backgroundOperation = nil
        }
    }
#endif
}
