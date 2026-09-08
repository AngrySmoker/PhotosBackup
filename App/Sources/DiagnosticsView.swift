import SwiftUI

/// The original feasibility-probe interface, preserved for engineering and support.
struct DiagnosticsView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var handoff: HandoffStore
    @EnvironmentObject private var probe: AuthProbe
    @State private var manualToken = ""
    @State private var showAdvanced = false
    private let setupURL = URL(string: "https://accounts.google.com/EmbeddedSetup")!

    var body: some View {
        List {
            Section("Environment") {
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("App Group handoff") {
                    Text(handoff.appGroupAvailable ? "Available" : "Inert (unsigned)")
                        .foregroundStyle(handoff.appGroupAvailable ? .green : .orange)
                }
                if let error = handoff.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
            }

            Section("Connection Flow") {
                Link(destination: setupURL) { Label("Open Google EmbeddedSetup", systemImage: "safari") }
                if let pending = handoff.pending {
                    LabeledContent("Pending token") {
                        Text("\(String(pending.oauthToken.prefix(6)))…\(String(pending.oauthToken.suffix(4)))").monospaced()
                    }
                }
                if probe.running { HStack { ProgressView(); Text("Running exchange…").foregroundStyle(.secondary) } }
            }

            Section("Feasibility Checklist") {
                ForEach(log.steps) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: item.state.symbol).foregroundStyle(item.state.tint)
                            Text(item.title)
                            Spacer()
                        }
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if probe.lastResult != nil {
                Section {
                    Button("Re-run Read-only Check") { Task { await probe.rerunReadAccess() } }.disabled(probe.running)
                }
            }

            Section {
                DisclosureGroup("Advanced: Paste oauth_token", isExpanded: $showAdvanced) {
                    TextField("oauth_token value", text: $manualToken, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced()).lineLimit(1...4)
                    Button("Run Exchange") {
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
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
