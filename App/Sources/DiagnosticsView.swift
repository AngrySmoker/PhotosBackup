import SwiftUI

/// The original feasibility-probe interface, preserved for engineering and support.
struct DiagnosticsView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var probe: AccountConnector
#if DEBUG
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
#endif
    @State private var manualToken = ""
    @State private var showAdvanced = false
    @State private var showingConnect = false

    var body: some View {
        List {
            Section("Environment") {
                LabeledRow("iOS", value: UIDevice.current.systemVersion)
            }

#if DEBUG
            Section {
                Button {
                    automaticBackup.simulateRun()
                } label: {
                    Label("Simulate Background Run", systemImage: "play.circle")
                }
                Text(automaticBackup.debugSimulationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Copy LLDB Launch Command") {
                    UIPasteboard.general.string = AutomaticBackupCoordinator.lldbSimulationCommand
                }
            } header: {
                Text("Background Debugging")
            } footer: {
                Text(AutomaticBackupCoordinator.lldbSimulationCommand)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
#endif

            Section("Connection Flow") {
                Button { showingConnect = true } label: {
                    Label("Connect Google Account", systemImage: "person.badge.key")
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
                    TextField("oauth_token value", text: $manualToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced()).lineLimit(4)
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
        .fullScreenCover(isPresented: $showingConnect) {
            AccountConnectView(
                onCaptured: { token in
                    showingConnect = false
                    Task { await probe.ingestWebToken(token) }
                },
                onCancel: { showingConnect = false }
            )
        }
    }
}
