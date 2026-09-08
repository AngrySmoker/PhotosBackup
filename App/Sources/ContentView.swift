import SwiftUI

struct ContentView: View {
    @EnvironmentObject var log: ProbeLog
    @EnvironmentObject var handoff: HandoffStore
    @EnvironmentObject var probe: AuthProbe

    @State private var manualToken = ""
    @State private var showAdvanced = false

    private let embeddedSetup = URL(string: "https://accounts.google.com/EmbeddedSetup")!

    var body: some View {
        NavigationStack {
            List {
                environmentSection
                flowSection
                checklistSection
                uploadsSection
                advancedSection
            }
            .navigationTitle("GPMC Auth Probe")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { markBuildStep() }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section("Environment") {
            LabeledContent("iOS", value: UIDevice.current.systemVersion)
            LabeledContent("App Group handoff") {
                Text(handoff.appGroupAvailable ? "available" : "inert (unsigned)")
                    .foregroundStyle(handoff.appGroupAvailable ? .green : .orange)
            }
            if !handoff.appGroupAvailable {
                Text("No paid team configured. The extension will fall back to the gpmcprobe:// URL handoff. Add a free personal team and rebuild to test the App Group path.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let err = handoff.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Flow

    private var flowSection: some View {
        Section("Run the flow") {
            Link(destination: embeddedSetup) {
                Label("Open Google EmbeddedSetup in Safari", systemImage: "safari")
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Sign in on the EmbeddedSetup page, tap I agree. The page may spin forever — that's expected.")
                step(2, "Open the GPMC Connect extension (tap the ᴀA / puzzle icon in Safari), tap Connect account.")
                step(3, "Return here. The exchange runs automatically when the token arrives.")
            }
            .font(.footnote)

            if let pending = handoff.pending {
                LabeledContent("Pending token") {
                    Text("\(pending.oauthToken.prefix(6))…\(pending.oauthToken.suffix(4))")
                        .monospaced()
                }
            }
            if probe.running {
                HStack { ProgressView(); Text("Running exchange…").foregroundStyle(.secondary) }
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").bold()
            Text(text)
        }
    }

    // MARK: - Checklist

    private var checklistSection: some View {
        Section("Feasibility checklist") {
            ForEach(log.steps) { s in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: s.state.symbol).foregroundStyle(s.state.tint)
                        Text(s.title)
                        Spacer()
                    }
                    if !s.detail.isEmpty {
                        Text(s.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 26)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Advanced

    private var uploadsSection: some View {
        Section {
            NavigationLink { UploadsView() } label: {
                Label("Uploads", systemImage: "arrow.up.doc")
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced: paste an oauth_token", isExpanded: $showAdvanced) {
                Text("Bypasses the Safari extension. Paste the accounts.google.com oauth_token cookie value to exercise the exchange path directly.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("oauth_token value", text: $manualToken, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .lineLimit(1...4)
                Button("Run exchange with pasted token") {
                    let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return }
                    log.set(ProbeLog.cookieRead, .skipped, "manual paste")
                    log.set(ProbeLog.nativeHandoff, .skipped, "manual paste")
                    log.set(ProbeLog.appIngest, .skipped, "manual paste")
                    Task { await probe.runExchange(oauthToken: token) }
                }
                .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || probe.running)
            }
        }
    }

    // MARK: -

    private func markBuildStep() {
        if log.steps.first(where: { $0.id == ProbeLog.build })?.state == .pending {
            log.set(ProbeLog.build, .passed,
                    "app + extension launched on iOS \(UIDevice.current.systemVersion)")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ProbeLog())
        .environmentObject(HandoffStore())
        .environmentObject(AuthProbe(log: ProbeLog()))
        .environmentObject(PhotosStack().account)
        .environmentObject(PhotosStack().queue)
}
