import SwiftUI

@main
struct PhotosBackupApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var log: ProbeLog
    @StateObject private var connector: AccountConnector
    @StateObject private var account: PhotosAccount
    @StateObject private var queue: UploadQueue
    @StateObject private var preferences: BackupPreferences
    @StateObject private var albums: PhotoAlbumStore
    @Environment(\.scenePhase) private var scenePhase
    private let network: NetworkPolicyMonitor
    private let automaticBackup: AutomaticBackupCoordinator

    init() {
        let sharedLog = ProbeLog()
        let sharedConnector = AccountConnector(log: sharedLog)
        let stack = PhotosStack()
        let preferences = BackupPreferences()
        let albums = PhotoAlbumStore()
        let network = NetworkPolicyMonitor()
        stack.queue.options.storageSaver = preferences.storageSaver
        stack.queue.options.useQuota = preferences.useQuota
        stack.queue.setMaxConcurrent(preferences.concurrentUploads)
        let automaticBackup = AutomaticBackupCoordinator(
            photos: stack,
            account: stack.account,
            queue: stack.queue,
            preferences: preferences,
            albums: albums,
            network: network
        )
        BackgroundFileUploadTransport.shared.setEventsDrainer { [weak automaticBackup] in
            await automaticBackup?.handleBackgroundURLSessionEvents()
        }
        // A successful exchange is what connects the account; the connector owns
        // the token, the stack owns everything downstream of it.
        sharedConnector.onExchange = { [weak stack] result in await stack?.connect(result) }
        _log = StateObject(wrappedValue: sharedLog)
        _connector = StateObject(wrappedValue: sharedConnector)
        _account = StateObject(wrappedValue: stack.account)
        _queue = StateObject(wrappedValue: stack.queue)
        _preferences = StateObject(wrappedValue: preferences)
        _albums = StateObject(wrappedValue: albums)
        self.network = network
        self.automaticBackup = automaticBackup
        network.onStatusChange = { [weak automaticBackup] _ in automaticBackup?.networkDidChange() }
        network.start()
        automaticBackup.applyNetworkPolicy()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(log)
                .environmentObject(connector)
                .environmentObject(account)
                .environmentObject(queue)
                .environmentObject(preferences)
                .environmentObject(albums)
                .environmentObject(automaticBackup)
                .task { await automaticBackup.start() }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        automaticBackup.applicationDidBecomeActive()
                    case .background:
                        automaticBackup.applicationDidEnterBackground()
                    default:
                        break
                    }
                }
                .onChange(of: preferences.connection) { _ in automaticBackup.connectionPreferenceDidChange() }
                .onChange(of: preferences.storageSaver) { value in queue.options.storageSaver = value }
                .onChange(of: preferences.useQuota) { value in queue.options.useQuota = value }
                .onChange(of: preferences.concurrentUploads) { value in queue.setMaxConcurrent(value) }
                .onChange(of: preferences.automaticBackup) { _ in automaticBackup.backupConfigurationDidChange() }
                .onChange(of: preferences.selectedAlbumIDs) { _ in automaticBackup.backupConfigurationDidChange() }
                .onChange(of: preferences.completedOnboarding) { _ in automaticBackup.backupConfigurationDidChange() }
                .onChange(of: account.status) { _ in automaticBackup.accountDidChange() }
        }
    }
}
