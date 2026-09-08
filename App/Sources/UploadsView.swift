import PhotosUI
import SwiftUI

/// The Google Photos half of the app: account state, a picker, and the activity
/// queue. Self-contained so it can be dropped into the probe's `List` as one
/// section or pushed as its own screen.
struct UploadsView: View {
    @EnvironmentObject var account: PhotosAccount
    @EnvironmentObject var queue: UploadQueue

    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        List {
            accountSection
            pickerSection
            if !queue.items.isEmpty { activitySection }
        }
        .navigationTitle("Uploads")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { items in
            guard !items.isEmpty else { return }
            selection = []
            Task {
                await MediaLibrary.requestReadAccess()
                queue.enqueue(MediaLibrary.sources(for: items))
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            switch account.status {
            case .loading:
                HStack { ProgressView(); Text("Checking saved credential…").foregroundStyle(.secondary) }
            case .disconnected:
                Text("No account connected. Complete the auth flow to connect one.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .connected(let email, let since):
                LabeledContent("Connected", value: email)
                LabeledContent("Since", value: since.formatted(date: .abbreviated, time: .shortened))
                Button("Check the credential") { Task { await account.verify() } }
                    .disabled(account.verifying)
                Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
            case .rejected(let email, let reason):
                Label(email.isEmpty ? "Credential rejected" : email, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
            }
            if let halt = queue.haltReason {
                Text(halt).font(.footnote).foregroundStyle(.red)
                Button("Resume the queue") { queue.resume() }
                    .disabled(!account.status.isUsable)
            }
        }
    }

    // MARK: - Picker

    private var pickerSection: some View {
        Section("Upload") {
            PhotosPicker(selection: $selection, maxSelectionCount: 50, matching: .any(of: [.images, .videos]),
                         photoLibrary: .shared()) {
                Label("Choose photos or videos", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(!account.status.isUsable)
            Toggle("Count against storage quota", isOn: $queue.options.useQuota)
            Toggle("Storage saver (re-encode)", isOn: $queue.options.storageSaver)
            Text("Live Photos upload as the still image only; the motion track is a follow-up.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            ForEach(queue.items) { item in row(item) }
        } header: {
            HStack {
                Text("Activity")
                Spacer()
                if !queue.isIdle { Text("\(queue.activeCount) left").font(.caption) }
            }
        } footer: {
            HStack(spacing: 16) {
                if queue.failedCount > 0 { Button("Retry failed") { queue.retryAllFailed() } }
                if !queue.isIdle { Button("Cancel all", role: .destructive) { queue.cancelAll() } }
                Button("Clear finished") { queue.clearFinished() }
            }
            .font(.footnote)
        }
    }

    private func row(_ item: UploadItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if item.byteCount > 0 {
                    Text(item.byteCount.formatted(.byteCount(style: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol(item.state)).foregroundStyle(tint(item.state))
                Text(item.state.label).font(.caption).foregroundStyle(.secondary)
            }
            if let fraction = item.state.fraction, item.state.isWorking {
                ProgressView(value: fraction)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            if item.state.isFinished {
                if item.state != .done && item.state != .alreadyBackedUp {
                    Button("Retry") { queue.retry(item.id) }
                }
            } else {
                Button("Cancel", role: .destructive) { queue.cancel(item.id) }
            }
        }
    }

    private func symbol(_ state: UploadItem.State) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .alreadyBackedUp: return "checkmark.circle"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle"
        case .queued, .waitingToRetry: return "clock"
        default: return "arrow.up.circle"
        }
    }

    private func tint(_ state: UploadItem.State) -> Color {
        switch state {
        case .done, .alreadyBackedUp: return .green
        case .failed: return .red
        case .cancelled, .waitingToRetry: return .orange
        default: return .blue
        }
    }
}
