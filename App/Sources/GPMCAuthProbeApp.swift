import SwiftUI

@main
struct GPMCAuthProbeApp: App {
    @StateObject private var log: ProbeLog
    @StateObject private var handoff = HandoffStore()
    @StateObject private var probe: AuthProbe
    @StateObject private var account: PhotosAccount
    @StateObject private var queue: UploadQueue
    @Environment(\.scenePhase) private var scenePhase
    private let photos: PhotosStack

    init() {
        let sharedLog = ProbeLog()
        let sharedProbe = AuthProbe(log: sharedLog)
        let stack = PhotosStack()
        // A successful exchange is what connects the account; the probe owns
        // the token, the stack owns everything downstream of it.
        sharedProbe.onExchange = { [weak stack] result in await stack?.connect(result) }
        _log = StateObject(wrappedValue: sharedLog)
        _probe = StateObject(wrappedValue: sharedProbe)
        photos = stack
        _account = StateObject(wrappedValue: stack.account)
        _queue = StateObject(wrappedValue: stack.queue)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(log)
                .environmentObject(handoff)
                .environmentObject(probe)
                .environmentObject(account)
                .environmentObject(queue)
                .task { await photos.start() }
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
