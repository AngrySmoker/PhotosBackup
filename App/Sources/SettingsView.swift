import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var preferences: BackupPreferences
    @Environment(\.openURL) private var openURL

    let showTutorial: () -> Void
    @State private var confirmDisconnect = false
    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!

    var body: some View {
        NavigationStack {
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
    }

    private var accountSection: some View {
        Section("Google Photos Account") {
            HStack(spacing: 12) {
                FeatureIcon(symbol: "person.crop.circle.fill", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Label(accountSubtitle, systemImage: account.status.isUsable ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(account.status.isUsable ? Color.green : Color.secondary)
                        .lineLimit(1)
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
                Button("Check Connection") { Task { await account.verify() } }
                    .disabled(account.verifying)
                Button("Disconnect Account", role: .destructive) { confirmDisconnect = true }
            } else {
                Button("Connect Account") { showTutorial() }
            }

            if let warning = account.persistenceWarning {
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
    }

    private var backupSection: some View {
        Section {
            Toggle("Automatic Backup", isOn: $preferences.automaticBackup)
            Picker("Use Connection", selection: $preferences.connection) {
                ForEach(BackupConnection.allCases) { option in Text(option.title).tag(option) }
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
            LabeledContent("Photos Backup Connect") {
                Text(extensionStatus)
                    .foregroundStyle(extensionReady ? Color.green : Color.orange)
            }
            Button("View Connection Tutorial") { showTutorial() }
            Button("Open App Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } header: {
            Text("Safari Extension")
        } footer: {
            Text("The extension securely passes your Google sign-in from Safari back to this app.")
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
            LabeledContent("App", value: "Photos Backup")
            LabeledContent("Version", value: appVersion)
            LabeledContent("iOS", value: UIDevice.current.systemVersion)
            LabeledContent("Core technology") {
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

    private var extensionReady: Bool {
        log.steps.first(where: { $0.id == ProbeLog.extensionEnabled })?.state == .passed
    }

    private var extensionStatus: String { extensionReady ? "Enabled" : "Not verified" }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}

struct ConnectionTutorialView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var probe: AuthProbe
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step = 0

    private let setupURL = URL(string: "https://accounts.google.com/EmbeddedSetup")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $step) {
                    tutorial(scene: .enableExtension, title: "Enable the extension first", detail: "In Settings, turn on Photos Backup Connect and allow access to accounts.google.com.", button: "Open App Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.tag(0)
                    safariGuidePage.tag(1)
                    tutorial(scene: .connect, title: account.status.isUsable ? "You’re connected" : "Connect your account", detail: account.status.isUsable ? "Photos Backup is ready to use." : "In Safari, open the extension and tap Connect account.", button: account.status.isUsable ? "Done" : "Return to Safari") {
                        if account.status.isUsable { dismiss() } else { openURL(setupURL) }
                    }.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
            .background(BackupTheme.background)
            .navigationTitle("Connect Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onChange(of: account.status) { if $0.isUsable { step = 2 } }
        }
    }

    private var safariGuidePage: some View {
        VStack(spacing: 18) {
            Spacer()
            SafariConnectionGuide().padding(.horizontal, 24)
            Text("Finish the connection in Safari").font(.title.bold()).multilineTextAlignment(.center)
            Text("Sign in, tap I agree, open Photos Backup Connect, then tap Connect to App.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Open Safari & Sign In") {
                step = 2
                openURL(setupURL)
            }
            .buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            Spacer()
        }
        .padding(.bottom, 26)
    }

    private func tutorial(scene: SafariTutorialCard.Scene, title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 18) {
            Spacer()
            SafariTutorialCard(scene: scene)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            if probe.running {
                HStack { ProgressView(); Text("Connecting…") }.font(.headline).frame(height: 52)
            } else {
                Button(button, action: action).buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 24)
            }
            if step < 2 { Button("Next") { withAnimation { step += 1 } }.font(.headline) }
            Spacer()
        }
        .padding(.bottom, 26)
    }
}
