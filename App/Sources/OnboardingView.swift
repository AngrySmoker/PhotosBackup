import Photos
import SwiftUI
import UIKit

struct OnboardingView: View {
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var handoff: HandoffStore
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var probe: AuthProbe
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @Environment(\.openURL) private var openURL

    @State private var step = 0
    @State private var appeared = false

    private let setupURL = URL(string: "https://accounts.google.com/EmbeddedSetup")!
    private let gpmcURL = URL(string: "https://github.com/xob0t/gpmc")!
    private let pageCount = 8

    var body: some View {
        ZStack {
            BackupTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                TabView(selection: $step) {
                    welcome.tag(0)
                    enableExtension.tag(1)
                    safariInstructions.tag(2)
                    connectionCheck.tag(3)
                    permission.tag(4)
                    chooseFolders.tag(5)
                    connectionPreference.tag(6)
                    complete.tag(7)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: step)
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            albums.refresh()
        }
        .onChange(of: account.status) { status in
            guard step == 3, status.isUsable else { return }
            advanceAfterVerifiedConnection()
        }
        .onChange(of: log.steps) { _ in
            guard step == 3 else { return }
            advanceAfterVerifiedConnection()
        }
    }

    private var topBar: some View {
        HStack {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Back")
            } else {
                Color.clear.frame(width: 34, height: 34)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? BackupTheme.blue : Color.secondary.opacity(0.22))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            Spacer()
            Color.clear.frame(width: 44, height: 34)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var welcome: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(BackupTheme.blue.opacity(0.08)).frame(width: 230, height: 230)
                    Circle().fill(BackupTheme.blue.opacity(0.10)).frame(width: 172, height: 172)
                    AppMark(size: 112)
                }
            ),
            eyebrow: "PHOTOS BACKUP",
            title: "Your memories, safely backed up",
            message: "Choose the albums that matter. Photos Backup keeps them protected in your Google Photos library.",
            primaryTitle: "Get Started",
            primaryAction: next,
            credit: "Built with GPMC by xob0t"
        )
    }

    private var permission: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(Color.pink.opacity(0.10)).frame(width: 220, height: 220)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 78, weight: .medium))
                        .foregroundStyle(.pink, .purple)
                }
            ),
            eyebrow: "YOUR LIBRARY",
            title: "Choose what to protect",
            message: "Allow photo access so you can pick albums and back up individual photos. Your library stays private on this device.",
            primaryTitle: permissionButtonTitle,
            primaryAction: {
                Task {
                    if albums.authorization == .notDetermined {
                        await albums.requestAccess()
                        if albums.canRead { next() }
                    } else if albums.canRead {
                        next()
                    } else {
                        openAppSettings()
                    }
                }
            },
            secondaryTitle: albums.authorization == .denied || albums.authorization == .restricted ? "Continue without access" : nil,
            secondaryAction: next
        )
    }

    private var enableExtension: some View {
        tutorialPage(
            scene: .enableExtension,
            eyebrow: "FIRST, ENABLE THE EXTENSION",
            title: "Turn on Photos Backup Connect",
            message: "Open Settings, find Safari Extensions, and enable Photos Backup Connect. Allow it on accounts.google.com.",
            primaryTitle: "Open App Settings",
            primaryAction: openAppSettings,
            secondaryTitle: "I’ve Enabled the Extension",
            secondaryAction: next
        )
    }

    private var safariInstructions: some View {
        VStack(spacing: 0) {
            SafariConnectionGuide().padding(.top, 18)
            Spacer(minLength: 16)
            Text("BEFORE YOU OPEN SAFARI").font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(BackupTheme.blue)
            Text("Here’s what to do in Safari").font(.title.bold()).multilineTextAlignment(.center).padding(.top, 7)
            Text("Finish every step before returning. The Google page may keep spinning after you tap I agree — that’s expected.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2).padding(.top, 9)
            Spacer(minLength: 16)
            Button("Open Safari & Sign In") {
                withAnimation { step = 3 }
                openURL(setupURL)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var connectionCheck: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(connectionTint.opacity(0.10)).frame(width: 220, height: 220)
                Circle().stroke(connectionTint.opacity(0.18), lineWidth: 8).frame(width: 154, height: 154)
                if probe.running {
                    ProgressView().controlSize(.large).tint(connectionTint).scaleEffect(1.35)
                } else {
                    Image(systemName: connectionVerified ? "checkmark.icloud.fill" : connectionFailed ? "exclamationmark.icloud.fill" : "iphone.and.arrow.forward")
                        .font(.system(size: 72, weight: .medium)).foregroundStyle(connectionTint)
                }
            }
            Spacer()
            Text(connectionEyebrow).font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(connectionTint)
            Text(connectionTitle).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 9)
            Text(connectionMessage).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
            Spacer()
            if !connectionVerified {
                Button(probe.running ? "Checking Connection…" : "Check Again") { checkForHandoff() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(probe.running)
                Button("Return to Safari") { openURL(setupURL) }.font(.headline).padding(.top, 14)
            }
        }
        .padding(24)
        .padding(.bottom, 8)
        .onAppear { checkForHandoff() }
    }

    private var chooseFolders: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                Text("CHOOSE ALBUMS").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(BackupTheme.blue)
                Text("What should we back up?").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("You can change this anytime in Folders.")
                    .font(.body).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                if albums.canRead {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(albums.albums.prefix(12)) { album in
                                AlbumSelectionRow(album: album, isSelected: preferences.selectedAlbumIDs.contains(album.id)) {
                                    preferences.toggle(albumID: album.id)
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    EmptyState(symbol: "photo.badge.exclamationmark", title: "Photo access is off", message: "You can choose albums later after allowing photo access in Settings.")
                    Spacer()
                }
            }

            VStack(spacing: 10) {
                Button(preferences.selectedAlbumIDs.isEmpty ? "Choose Later" : "Continue") { next() }
                    .buttonStyle(PrimaryButtonStyle())
                Text("\(preferences.selectedAlbumIDs.count) selected")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private var connectionPreference: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            FeatureIcon(symbol: "wifi", size: 76)
            Text("When should we back up?")
                .font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 24)
            Text("Choose how Photos Backup uses your connection.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 10)

            VStack(spacing: 12) {
                ForEach(BackupConnection.allCases) { option in
                    Button { preferences.connection = option } label: {
                        HStack(spacing: 14) {
                            FeatureIcon(symbol: option == .wifiOnly ? "wifi" : "antenna.radiowaves.left.and.right", size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.title).font(.headline).foregroundStyle(.primary)
                                Text(option.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: preferences.connection == option ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(preferences.connection == option ? BackupTheme.blue : .secondary)
                        }
                        .padding(16)
                        .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(preferences.connection == option ? BackupTheme.blue : .clear, lineWidth: 2))
                    }
                }
            }
            .padding(.top, 28)

            Toggle("Back up selected albums automatically", isOn: $preferences.automaticBackup)
                .font(.subheadline.weight(.medium))
                .padding(.top, 22)
            Spacer()
            Button("Continue") { next() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
    }

    private var complete: some View {
        onboardingPage(
            artwork: AnyView(
                ZStack {
                    Circle().fill(Color.green.opacity(0.11)).frame(width: 220, height: 220)
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 86, weight: .medium))
                        .foregroundStyle(.green)
                }
            ),
            eyebrow: "ALL SET",
            title: "Your backup is ready",
            message: completionMessage,
            primaryTitle: "Go to Photos Backup",
            primaryAction: finish
        )
    }

    private func onboardingPage(
        artwork: AnyView,
        eyebrow: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: @escaping () -> Void = {},
        credit: String? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Spacer()
            artwork
            Spacer()
            Text(eyebrow).font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(BackupTheme.blue)
            Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center).padding(.top, 9)
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).padding(.top, 12)
            Spacer()
            Button(primaryTitle, action: primaryAction).buttonStyle(PrimaryButtonStyle())
            if let secondaryTitle {
                Button(secondaryTitle, action: secondaryAction)
                    .font(.headline).padding(.top, 14)
            }
            if let credit {
                Link(credit, destination: gpmcURL)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                    .accessibilityHint("Opens the GPMC project on GitHub")
            }
        }
        .padding(24)
        .padding(.bottom, 8)
    }

    private func tutorialPage(
        scene: SafariTutorialCard.Scene,
        eyebrow: String,
        title: String,
        message: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondaryAction: @escaping () -> Void = {},
        isWorking: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            SafariTutorialCard(scene: scene).padding(.top, 18)
            Spacer(minLength: 18)
            Text(eyebrow).font(.caption.weight(.bold)).tracking(1.3).foregroundStyle(BackupTheme.blue)
            Text(title).font(.title.bold()).multilineTextAlignment(.center).padding(.top, 7)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(2).padding(.top, 9)
            Spacer(minLength: 16)
            if isWorking {
                HStack { ProgressView(); Text("Connecting securely…") }
                    .font(.headline).foregroundStyle(.secondary).frame(height: 50)
            } else {
                Button(primaryTitle, action: primaryAction).buttonStyle(PrimaryButtonStyle())
            }
            if let secondaryTitle {
                Button(secondaryTitle, action: secondaryAction).font(.headline).padding(.top, 13)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var permissionButtonTitle: String {
        switch albums.authorization {
        case .authorized, .limited: return "Continue"
        case .denied, .restricted: return "Open Settings"
        default: return "Allow Photo Access"
        }
    }

    private var completionMessage: String {
        let count = preferences.selectedAlbumIDs.count
        return count == 0
            ? "Your account is connected. You can choose albums from the Folders tab."
            : "Your account is connected, and we’ll keep \(count) selected \(count == 1 ? "album" : "albums") protected."
    }

    private func next() { withAnimation { step = min(pageCount - 1, step + 1) } }
    private func finish() { preferences.completedOnboarding = true }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var connectionFailed: Bool {
        logState(ProbeLog.masterToken) == .failed || logState(ProbeLog.photosToken) == .failed || logState(ProbeLog.readAccess) == .failed
    }

    private var connectionVerified: Bool {
        guard account.status.isUsable else { return false }
        // A fresh handoff must pass the Photos read check. A restored account
        // has no in-memory exchange result, so its successful credential
        // restoration is sufficient and Settings still offers Verify.
        return probe.lastResult == nil || logState(ProbeLog.readAccess) == .passed
    }

    private var connectionTint: Color {
        if connectionVerified { return .green }
        if connectionFailed { return .orange }
        return BackupTheme.blue
    }

    private var connectionEyebrow: String {
        if connectionVerified { return "CONNECTION VERIFIED" }
        if connectionFailed { return "COULDN’T CONNECT" }
        return probe.running ? "VERIFYING ACCOUNT" : "WAITING FOR SAFARI"
    }

    private var connectionTitle: String {
        if connectionVerified { return "You’re connected" }
        if connectionFailed { return "Let’s try that again" }
        return probe.running ? "Checking your account…" : "Finish in Safari"
    }

    private var connectionMessage: String {
        if connectionVerified { return "Photos Backup verified your Google Photos account. You’re ready to continue." }
        if connectionFailed {
            return "We received the sign-in, but couldn’t verify it. Return to Safari, sign in again, tap I agree, then reconnect from the extension."
        }
        return probe.running
            ? "We securely received the extension handoff and are verifying your Google Photos access."
            : "After tapping Connect to App in the extension, return here. We’ll verify everything before continuing."
    }

    private func logState(_ id: String) -> ProbeStep.State? {
        probe.log.steps.first(where: { $0.id == id })?.state
    }

    private func checkForHandoff() {
        if let pending = handoff.drainAppGroup() {
            Task { await probe.handle(pending) { handoff.consume() } }
        } else if account.status.isUsable {
            Task { await account.verify() }
        }
    }

    private func advanceAfterVerifiedConnection() {
        guard connectionVerified else { return }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if step == 3, connectionVerified { withAnimation { step = 4 } }
        }
    }
}

struct AlbumSelectionRow: View {
    let album: PhotoAlbum
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                FeatureIcon(symbol: album.symbol, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text("\(album.count.formatted()) items").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isSelected ? BackupTheme.blue : .secondary)
            }
            .padding(14)
            .background(BackupTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
