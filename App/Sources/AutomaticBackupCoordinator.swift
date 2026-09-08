import BackgroundTasks
import Foundation
import OSLog

/// Owns opportunistic automatic-backup runs in both foreground and system
/// background execution windows. iOS decides when a processing request runs;
/// every invocation submits its successor so the work remains recurring.
@MainActor
final class AutomaticBackupCoordinator {
    static let taskIdentifier = "com.g8row.photosbackup.background-backup"
    private static let logger = Logger(subsystem: "com.g8row.photosbackup", category: "automatic-backup")

    private let photos: PhotosStack
    private let account: PhotosAccount
    private let queue: UploadQueue
    private let preferences: BackupPreferences
    private let albums: PhotoAlbumStore
    private let network: NetworkPolicyMonitor

    private var registered = false
    private var ranForegroundBackup = false
    private var isForeground = true
    private var shouldRunAfterActivation = false
    private var backgroundOperation: Task<Void, Never>?

    init(photos: PhotosStack,
         account: PhotosAccount,
         queue: UploadQueue,
         preferences: BackupPreferences,
         albums: PhotoAlbumStore,
         network: NetworkPolicyMonitor) {
        self.photos = photos
        self.account = account
        self.queue = queue
        self.preferences = preferences
        self.albums = albums
        self.network = network

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
        ranForegroundBackup = false
        updateSchedule()
        runForegroundBackupIfNeeded()
    }

    func accountDidChange() {
        queue.activateAccount(account.status.email)
        runForegroundBackupIfNeeded()
    }

    func applicationDidEnterBackground() {
        isForeground = false
        shouldRunAfterActivation = true
        updateSchedule()
    }

    func applicationDidBecomeActive() {
        isForeground = true
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
    }

    private func runForegroundBackupIfNeeded() {
        guard isForeground,
              !ranForegroundBackup,
              shouldSchedule,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return }

        albums.refresh()
        guard albums.canRead else { return }
        ranForegroundBackup = true
        queue.enqueue(albums.sources(for: preferences.selectedAlbumIDs), skippingExisting: true, limit: 250)
    }

    private func begin(_ task: BGProcessingTask) {
        Self.logger.info("Beginning an iOS background-processing window")
        updateSchedule()
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

        guard shouldSchedule,
              account.status.isUsable,
              preferences.connection.decision(for: network.status).allowsUploads else { return false }

        albums.refresh()
        guard albums.canRead else { return false }
        let failuresBefore = queue.failedCount
        queue.enqueue(albums.sources(for: preferences.selectedAlbumIDs), skippingExisting: true, limit: 25)
        let settled = await queue.waitUntilSettled()
        return settled && queue.failedCount == failuresBefore
    }
}
