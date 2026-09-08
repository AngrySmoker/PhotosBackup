import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences

    let showTutorial: () -> Void
    @State private var confirmDisconnect = false
    @State private var connectionCheckResult: PhotosAccount.VerificationOutcome?
    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!

    var body: some View {
        NavigationView {
            Form {
                accountSection
                backupSection
                safariSection
                supportSection
                aboutSection
            }
            .navigationTitle("Settings")
            .confirmationDialog("Disconnect Google Photos?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await account.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New backups will stop until you connect again. Photos already backed up are not affected.")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var accountSection: some View {
        Section("Google Photos Account") {
            HStack(alignment: .top, spacing: 12) {
                FeatureIcon(symbol: "person.crop.circle.fill", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(account.status.isUsable ? Color.green : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer()
                Image(systemName: account.status.isUsable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(account.status.isUsable ? Color.green : Color.orange)
                    .accessibilityLabel(account.status.isUsable ? "Connected" : "Action needed")
            }
            .padding(.vertical, 4)

            if account.status.isUsable {
                Button {
                    connectionCheckResult = nil
                    Task {
                        let result = await account.verify()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            connectionCheckResult = result
                        }
                    }
                } label: {
                    HStack {
                        Text(account.verifying ? "Checking Connection…" : "Check Connection")
                        Spacer()
                        if account.verifying {
                            ProgressView()
                        } else if connectionCheckResult == .succeeded {
                            Label("Verified", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                    .disabled(account.verifying)
                Button("Disconnect Account", role: .destructive) { confirmDisconnect = true }
            } else {
                Button("Connect Account") { showTutorial() }
            }

            if case .failed(let reason) = connectionCheckResult, account.status.isUsable {
                Label(reason, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if account.status.isUsable, let warning = account.persistenceWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Not saved to Keychain", systemImage: "key.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(warning + " The account works for this session but may need to be connected again after relaunch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
        }
        .onChange(of: account.status) { status in
            if !status.isUsable { connectionCheckResult = nil }
        }
    }

    private var backupSection: some View {
        Section {
            Toggle("Automatic Backup", isOn: $preferences.automaticBackup)
            Picker("Use Connection", selection: $preferences.connection) {
                ForEach(BackupConnection.allCases) { option in Text(option.title).tag(option) }
            }
            if let reason = queue.networkPauseReason {
                Label(reason, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Toggle("Storage Saver", isOn: $queue.options.storageSaver)
            Toggle("Count Against Storage Quota", isOn: $queue.options.useQuota)
        } header: {
            Text("Backup")
        } footer: {
            Text("Storage Saver asks Google Photos to reduce file size. Live Photos currently back up as still images.")
        }
    }

    private var safariSection: some View {
        Section {
            Button("Connect Account") { showTutorial() }
        } header: {
            Text("Connection")
        } footer: {
            Text("Sign in to Google in a secure in-app window to connect your Google Photos account.")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            NavigationLink("Diagnostics") { DiagnosticsView() }
            Button("Run Onboarding Again") {
                preferences.resetOnboarding()
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledRow("App", value: "Photos Backup")
            LabeledRow("Version", value: appVersion)
            LabeledRow("iOS", value: UIDevice.current.systemVersion)
            LabeledRow("Core technology") {
                Link("GPMC by xob0t", destination: gpmcURL)
            }
        }
    }

    private var accountTitle: String {
        switch account.status {
        case .loading: return "Checking account…"
        case .disconnected: return "Not connected"
        case .connected(let email, _): return email
        case .rejected(let email, _): return email.isEmpty ? "Sign in again" : email
        }
    }

    private var accountSubtitle: String {
        switch account.status {
        case .loading: return "Looking for a saved credential"
        case .disconnected: return "Connect to start backing up"
        case .connected(_, let since): return "Connected · \(since.formatted(date: .abbreviated, time: .omitted))"
        case .rejected(_, let reason): return reason
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Presents the in-app Google account connection flow (see AccountConnectView)
/// and runs the token exchange on capture. Shown as a sheet from the dashboard
/// and Settings.
struct ConnectionTutorialView: View {
    @EnvironmentObject private var probe: AccountConnector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AccountConnectView(
            onCaptured: { token in
                dismiss()
                Task { await probe.ingestWebToken(token) }
            },
            onCancel: { dismiss() }
        )
    }
}
