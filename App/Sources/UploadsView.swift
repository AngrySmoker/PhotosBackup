import SwiftUI

struct UploadsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @State private var showPicker = false

    var body: some View {
        NavigationView {
            List {
                manualBackupSection
                if queue.activeCount > 0, let reason = queue.pauseReason { pausedSection(reason) }
                if let warning = queue.persistenceWarning { persistenceWarningSection(warning) }
                if queue.items.isEmpty { emptySection }
                else { activitySection }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if queue.items.contains(where: { $0.state.isFinished }) {
                        Button("Clear") { queue.clearFinished() }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { sources in enqueue(sources) }.ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func enqueue(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        queue.enqueue(sources, skippingExisting: true)
    }

    private var manualBackupSection: some View {
        Section {
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    FeatureIcon(symbol: "photo.badge.plus", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose Photos or Videos").font(.headline).foregroundStyle(.primary)
                        Text("Back up to 50 items at once").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(!account.status.isUsable)
        } footer: {
            if !account.status.isUsable { Text("Connect a Google Photos account before starting a backup.") }
        }
    }

    private func pausedSection(_ reason: String) -> some View {
        Section {
            Label("Backup Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            Text(reason).font(.footnote).foregroundStyle(.secondary)
            if queue.haltReason != nil {
                Button("Resume Backup") { queue.resume() }.disabled(!account.status.isUsable)
            }
        }
    }

    private func persistenceWarningSection(_ warning: String) -> some View {
        Section {
            Label("Upload Progress Isn’t Saved", systemImage: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text(warning).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var emptySection: some View {
        Section {
            EmptyState(symbol: "tray", title: "No backup activity", message: "Photos you back up manually or from selected albums will appear here.")
                .listRowBackground(Color.clear)
        }
    }

    private var activitySection: some View {
        Section {
            if !queue.isIdle {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Overall Progress").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(queue.overallFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: queue.overallFraction).tint(BackupTheme.blue)
                }
                .padding(.vertical, 6)
            }
            ForEach(queue.items) { item in activityRow(item) }
        } header: {
            HStack {
                Text("Uploads")
                Spacer()
                if !queue.isIdle { Text("\(queue.activeCount) remaining") }
            }
        } footer: {
            HStack(spacing: 18) {
                if queue.failedCount > 0 { Button("Retry Failed") { queue.retryAllFailed() } }
                if !queue.isIdle { Button("Cancel All", role: .destructive) { queue.cancelAll() } }
            }
        }
    }

    private func activityRow(_ item: UploadItem) -> some View {
        HStack(spacing: 12) {
            FeatureIcon(symbol: symbol(item.state), color: tint(item.state), size: 42)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if item.byteCount > 0 {
                        Text(item.byteCount.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(item.state.label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let fraction = item.state.fraction, item.state.isWorking {
                    ProgressView(value: fraction).tint(BackupTheme.blue)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            if item.state.isFinished {
                if item.state != .done && item.state != .alreadyBackedUp {
                    Button("Retry") { queue.retry(item.id) }.tint(BackupTheme.blue)
                }
            } else {
                Button("Cancel", role: .destructive) { queue.cancel(item.id) }
            }
        }
    }

    private func symbol(_ state: UploadItem.State) -> String {
        switch state {
        case .done, .alreadyBackedUp: return "checkmark"
        case .failed: return "exclamationmark"
        case .cancelled: return "xmark"
        case .queued, .waitingToRetry: return "clock"
        default: return "arrow.up"
        }
    }

    private func tint(_ state: UploadItem.State) -> Color {
        switch state {
        case .done, .alreadyBackedUp: return .green
        case .failed: return .red
        case .cancelled, .waitingToRetry: return .orange
        default: return BackupTheme.blue
        }
    }
}
