import SwiftUI

struct DashboardView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore

    let onConnect: () -> Void
    let onAccount: () -> Void
    @State private var showPicker = false
    @State private var showingStopBackupConfirmation = false

    private var selectedAlbums: [PhotoAlbum] {
        albums.albums.filter { preferences.selectedAlbumIDs.contains($0.id) }
    }

    /// Unique-item estimate for the selection. "All Photos" spans the whole
    /// image/video library, so when it is selected every other album is a
    /// subset of it — summing per-album counts would count most assets twice.
    private var selectedItemCount: Int {
        if let all = selectedAlbums.first(where: { $0.isAllPhotos }) { return all.count }
        return selectedAlbums.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(spacing: 16) {
                    accountBanner
                    backupHero
                    quickActions
                    folderSummary
                    if !queue.items.isEmpty { recentActivity }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(BackupTheme.background)
            .navigationTitle("Photos Backup")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    accountToolbarItem
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { sources in enqueue(sources) }.ignoresSafeArea()
            }
            .confirmationDialog(
                "Stop all backups?",
                isPresented: $showingStopBackupConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop Backup", role: .destructive) { stopBackup() }
                Button("Keep Backing Up", role: .cancel) {}
            } message: {
                Text(stopBackupMessage)
            }
            .onAppear { albums.refresh() }
        }
        .navigationViewStyle(.stack)
    }

    private func enqueue(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        queue.enqueue(sources, skippingExisting: true)
    }

    @ViewBuilder private var accountBanner: some View {
        switch account.status {
        case .loading:
            banner(color: .blue, symbol: "hourglass", title: "Checking your account", message: "Just a moment…")
        case .disconnected:
            Button(action: onConnect) {
                banner(color: .orange, symbol: "person.crop.circle.badge.exclamationmark", title: "Connect Google Photos", message: "Sign in to start protecting your library", showsChevron: true)
            }
            .buttonStyle(.plain)
        case .connected:
            if let warning = account.persistenceWarning {
                banner(color: .orange, symbol: "key.slash", title: "Not saved to Keychain", message: warning, showsChevron: false)
            } else if queue.activeCount > 0, let reason = queue.pauseReason {
                banner(color: .orange, symbol: "pause.circle.fill", title: "Backup paused", message: reason, showsChevron: false)
            }
        case .rejected(_, let reason):
            Button(action: onConnect) {
                banner(color: .red, symbol: "exclamationmark.arrow.circlepath", title: "Sign in again", message: reason, showsChevron: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var backupHero: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(heroTitle).font(.title2.bold())
                    Text(heroSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                ZStack {
                    Circle().stroke(heroTint.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: heroProgress)
                        .stroke(heroTint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: heroSymbol)
                        .font(.title3.bold())
                        .foregroundStyle(heroTint)
                }
                .frame(width: 58, height: 58)
            }

            Divider()

            HStack {
                metric(value: preferences.backedUpCount.formatted(), label: "Backed up")
                Divider().frame(height: 38)
                metric(value: selectedAlbums.count.formatted(), label: "Albums")
                Divider().frame(height: 38)
                metric(value: queue.activeCount.formatted(), label: "In queue")
            }

            if !queue.isIdle {
                HStack(spacing: 10) {
                    if queue.isUserPaused {
                        Button {
                            queue.resumeUserPausedUploads()
                        } label: {
                            Label("Resume", systemImage: "play.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(BackupTheme.blue)
                        .disabled(!account.status.isUsable)
                    } else if queue.pauseReason == nil {
                        Button {
                            queue.pauseAfterCurrentUploads()
                        } label: {
                            Label("Pause", systemImage: "pause.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(BackupTheme.blue)
                        .accessibilityHint("Lets uploads in progress finish, then holds the remaining queue")
                    }

                    Button(role: .destructive) {
                        showingStopBackupConfirmation = true
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(20)
        .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder private var quickActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) { albumBackupAction; photoPickerAction }
                .buttonStyle(CardButtonStyle())
        } else {
            HStack(spacing: 12) { albumBackupAction; photoPickerAction }
                .buttonStyle(CardButtonStyle())
        }
    }

    private var albumBackupAction: some View {
        let enabled = account.status.isUsable && !selectedAlbums.isEmpty && queue.isIdle
        return Button(action: backUpSelectedAlbums) {
            quickActionLabel(symbol: "arrow.up.circle.fill", title: "Back Up Now", detail: selectedAlbums.isEmpty ? "Choose albums first" : "\(selectedItemCount.formatted()) items", isEnabled: enabled)
        }
        .disabled(!enabled)
    }

    private var photoPickerAction: some View {
        let enabled = account.status.isUsable
        return Button { showPicker = true } label: {
            quickActionLabel(symbol: "photo.badge.plus", title: "Pick Photos", detail: "Manual backup", isEnabled: enabled)
        }
        .disabled(!enabled)
    }

    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Selected Albums").font(.headline)
                Spacer()
                if preferences.automaticBackup {
                    StatusPill(text: "Automatic", symbol: "arrow.triangle.2.circlepath", color: .green)
                }
            }
            if selectedAlbums.isEmpty {
                Text("No albums selected yet. Choose albums from the Albums tab.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(Array(selectedAlbums.prefix(4).enumerated()), id: \.element.id) { index, album in
                    if index > 0 { Divider().padding(.leading, 54) }
                    HStack(spacing: 12) {
                        FeatureIcon(symbol: album.symbol, size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title).font(.subheadline.weight(.semibold))
                            Text("\(album.count.formatted()) items").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(BackupTheme.blue)
                    }
                }
                if selectedAlbums.count > 4 {
                    Text("+ \(selectedAlbums.count - 4) more albums")
                        .font(.footnote.weight(.semibold)).foregroundStyle(BackupTheme.blue)
                }
            }
        }
        .padding(18)
        .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity").font(.headline)
            ForEach(Array(queue.items.suffix(3).reversed())) { item in
                HStack(spacing: 12) {
                    FeatureIcon(symbol: symbol(item.state), color: tint(item.state), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var accountToolbarItem: some View {
        Button(action: onAccount) {
            ZStack {
                Circle().fill(account.status.isUsable ? BackupTheme.blue : Color.secondary.opacity(0.18))
                Image(systemName: account.status.isUsable ? "person.fill" : "person.crop.circle.badge.exclamationmark")
                    .font(.caption.weight(.bold)).foregroundStyle(account.status.isUsable ? .white : .secondary)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.status.isUsable ? "Account connected" : "Account not connected")
        .accessibilityHint("Opens account settings")
    }

    private func banner(color: Color, symbol: String, title: String, message: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
        }
        .padding(14)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickActionLabel(symbol: String, title: String, detail: String, isEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(isEnabled ? BackupTheme.blue : Color.secondary)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var heroTitle: String {
        if !account.status.isUsable { return "Connect to back up" }
        if queue.activeCount > 0, queue.pauseReason != nil { return "Backup paused" }
        if !queue.isIdle { return "Backing up…" }
        if queue.failedCount > 0 { return "Backup needs attention" }
        if preferences.backedUpCount == 0 { return "Ready to back up" }
        return "Backup complete"
    }

    private var heroSubtitle: String {
        if !account.status.isUsable { return "Connect an account to get started" }
        if !queue.isIdle { return "\(queue.activeCount) items remaining" }
        if queue.failedCount > 0 { return "\(queue.failedCount) items failed — open Activity to retry" }
        if selectedAlbums.isEmpty { return "Choose albums to protect" }
        return "Your selected albums are up to date"
    }

    private var heroProgress: Double {
        if !account.status.isUsable || (queue.activeCount > 0 && queue.pauseReason != nil) { return 0.18 }
        return queue.isIdle ? 1 : max(queue.overallFraction, 0.04)
    }

    private var heroTint: Color {
        if !account.status.isUsable || (queue.activeCount > 0 && queue.pauseReason != nil) { return .orange }
        if queue.failedCount > 0 { return .red }
        return queue.isIdle ? .green : BackupTheme.blue
    }

    private var heroSymbol: String {
        if !account.status.isUsable { return "link" }
        if queue.activeCount > 0, queue.pauseReason != nil { return "pause.fill" }
        if queue.failedCount > 0 { return "exclamationmark" }
        return queue.isIdle ? "checkmark" : "arrow.up"
    }

    private func backUpSelectedAlbums() {
        let sources = albums.sources(for: preferences.selectedAlbumIDs)
        queue.enqueue(sources, skippingExisting: true)
    }

    private var stopBackupMessage: String {
        if preferences.automaticBackup {
            return "Uploads in progress will be cancelled, the remaining queue will be stopped, and Automatic Backup will be turned off."
        }
        return "Uploads in progress will be cancelled and the remaining queue will be stopped."
    }

    private func stopBackup() {
        preferences.automaticBackup = false
        queue.cancelAll()
    }

    private func symbol(_ state: UploadItem.State) -> String {
        switch state {
        case .done, .alreadyBackedUp: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .queued, .waitingToRetry, .waitingForICloud: return "clock"
        default: return "arrow.up"
        }
    }

    private func tint(_ state: UploadItem.State) -> Color {
        switch state {
        case .done, .alreadyBackedUp: return .green
        case .failed: return .red
        case .cancelled, .waitingToRetry, .waitingForICloud: return .orange
        default: return BackupTheme.blue
        }
    }
}
