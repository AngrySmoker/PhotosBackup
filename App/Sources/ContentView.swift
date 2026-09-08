import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @State private var ranAutomaticBackup = false

    var body: some View {
        Group {
            if preferences.completedOnboarding {
                MainAppView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .tint(BackupTheme.blue)
        .animation(.easeInOut(duration: 0.3), value: preferences.completedOnboarding)
        .onAppear { markBuildStep() }
        .onChange(of: queue.items) { preferences.observeCompletedUploads($0) }
        .onChange(of: account.status) { status in
            guard status.isUsable else { return }
            runAutomaticBackupIfNeeded()
        }
    }

    private func markBuildStep() {
        if log.steps.first(where: { $0.id == ProbeLog.build })?.state == .pending {
            log.set(ProbeLog.build, .passed, "app + extension launched on iOS \(UIDevice.current.systemVersion)")
        }
    }

    private func runAutomaticBackupIfNeeded() {
        guard !ranAutomaticBackup,
              preferences.completedOnboarding,
              preferences.automaticBackup,
              !preferences.selectedAlbumIDs.isEmpty else { return }
        ranAutomaticBackup = true
        albums.refresh()
        queue.enqueue(albums.sources(for: preferences.selectedAlbumIDs))
    }
}

private struct MainAppView: View {
    @State private var selectedTab = 0
    @State private var showConnectionTutorial = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView { showConnectionTutorial = true }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            FolderSelectionView()
                .tabItem { Label("Folders", systemImage: "rectangle.stack.fill") }
                .tag(1)

            UploadsView()
                .tabItem { Label("Activity", systemImage: "arrow.up.circle.fill") }
                .tag(2)

            SettingsView { showConnectionTutorial = true }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .sheet(isPresented: $showConnectionTutorial) {
            ConnectionTutorialView()
        }
    }
}
