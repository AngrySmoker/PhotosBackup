import Foundation

/// Drives the credential half of the checklist: everything from a captured
/// oauth_token onward. The Safari-side steps (enable, permission, cookie read,
/// handoff) are marked by the app as evidence arrives.
@MainActor
final class AccountConnector: ObservableObject {
    let log: ProbeLog
    @Published var running = false
    /// Called with a usable exchange result so the Photos side can adopt the
    /// credential. Set by the app entry point.
    var onExchange: ((TokenExchange.Result) async -> Void)?
    /// Held in memory only, for the life of the process. A fresh oauth_token
    /// costs a full interactive sign-in, so while the Photos wire format is
    /// being debugged step 9 has to be repeatable against the same credential.
    @Published private(set) var lastResult: TokenExchange.Result?

    init(log: ProbeLog) {
        self.log = log
    }

    /// Record that a handoff arrived, then run the exchange.
    func handle(_ handoff: Handoff, then consume: @escaping () -> Void) async {
        log.set(ProbeLog.nativeHandoff, .passed,
                "channel: \(handoff.channel), captured \(Self.rel(handoff.capturedAt))")
        log.set(ProbeLog.appIngest, .passed,
                "token length \(handoff.oauthToken.count); source cleared after read")
        // If we got here the extension necessarily read the cookie and was
        // permitted to; reflect that unless already explicitly failed.
        markInferred(ProbeLog.cookieRead, "inferred from a successful handoff")
        markInferred(ProbeLog.hostPermission, "inferred: cookies.get returned a value")
        markInferred(ProbeLog.extensionEnabled, "inferred: extension delivered a native message")

        await runExchange(oauthToken: handoff.oauthToken)
        consume()
    }

    func runExchange(oauthToken: String) async {
        guard !running else { return }
        running = true
        defer { running = false }

        log.reset(from: ProbeLog.masterToken)
        log.set(ProbeLog.masterToken, .running)

        let result: TokenExchange.Result
        do {
            result = try await TokenExchange.run(oauthToken: oauthToken)
        } catch let f as TokenExchange.Failure {
            let failedStep = f.stage == "photos token" ? ProbeLog.photosToken : ProbeLog.masterToken
            if failedStep == ProbeLog.photosToken { log.set(ProbeLog.masterToken, .passed) }
            log.set(failedStep, .failed, f.message)
            return
        } catch {
            log.set(ProbeLog.masterToken, .failed, error.localizedDescription)
            return
        }

        log.set(ProbeLog.masterToken, .passed,
                "account: \(result.email) · androidId: \(result.androidId)")
        log.set(ProbeLog.photosToken, result.encrypted ? .skipped : .passed,
                result.encrypted
                    ? "TokenEncrypted=1 — bound token, not decoded by this connector"
                    : "access token issued" + (result.photosTokenExpiry.map { ", expires \(Self.rel($0))" } ?? ""))

        if result.encrypted {
            log.set(ProbeLog.readAccess, .skipped, "skipped: no usable access token")
            return
        }

        lastResult = result
        await onExchange?(result)
        await checkReadAccess(result)
    }

    /// Re-run step 9 against the credential from the last exchange. The Photos
    /// access token outlives the single-use oauth_token by many hours, so this
    /// is the cheap way to iterate on the read path.
    func rerunReadAccess() async {
        guard let result = lastResult, !running else { return }
        running = true
        defer { running = false }
        await checkReadAccess(result)
    }

    private func checkReadAccess(_ result: TokenExchange.Result) async {
        log.set(ProbeLog.readAccess, .running)
        do {
            let client = try GPMCClient(authData: result.authData)
            try await client.validateReadAccess()
            log.set(ProbeLog.readAccess, .passed, "dummy hash lookup accepted by photosdata-pa")
        } catch {
            log.set(ProbeLog.readAccess, .failed, (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription)
        }
    }

    private func markInferred(_ id: String, _ note: String) {
        if log.steps.first(where: { $0.id == id })?.state != .failed {
            log.set(id, .passed, note)
        }
    }

    static func rel(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
