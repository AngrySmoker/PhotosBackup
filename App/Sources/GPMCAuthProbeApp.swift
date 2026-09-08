import SwiftUI

@main
struct GPMCAuthProbeApp: App {
    @StateObject private var log: ProbeLog
    @StateObject private var handoff = HandoffStore()
    @StateObject private var probe: AuthProbe
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let sharedLog = ProbeLog()
        _log = StateObject(wrappedValue: sharedLog)
        _probe = StateObject(wrappedValue: AuthProbe(log: sharedLog))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(log)
                .environmentObject(handoff)
                .environmentObject(probe)
                .onOpenURL { url in
                    if let h = handoff.ingest(url: url) {
                        Task { await probe.handle(h) { handoff.consume() } }
                    }
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    if let h = handoff.drainAppGroup() {
                        Task { await probe.handle(h) { handoff.consume() } }
                    }
                }
        }
    }
}
