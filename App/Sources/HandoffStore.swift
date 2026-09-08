import Foundation

/// A captured `oauth_token` on its way from the Safari extension to the app.
struct Handoff: Equatable {
    let oauthToken: String
    let domain: String
    let capturedAt: Date
    let channel: String   // "appgroup" | "url"
}

/// Receives the extension's handoff and enforces single use.
///
/// Two inbound channels:
///   - App Group file, written by `SafariWebExtensionHandler` (production path).
///   - `gpmcprobe://token?value=…` URL, used only when the App Group entitlement
///     is inert (unsigned simulator build). Probe-only; never ship this.
///
/// The token is held in memory just long enough for the exchange to run; the
/// source (file or nothing) is cleared immediately on read.
@MainActor
final class HandoffStore: ObservableObject {
    static let appGroupID = "group.dev.gpmc.authprobe"
    private static let filename = "handoff.json"

    @Published private(set) var pending: Handoff?
    @Published private(set) var lastError: String?

    var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) != nil
    }

    /// Pull a token written by the extension into the App Group, then delete it.
    @discardableResult
    func drainAppGroup() -> Handoff? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            return nil
        }
        let url = container.appendingPathComponent(Self.filename)
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Consume first: even if parsing fails we do not want a stale token to linger.
        try? FileManager.default.removeItem(at: url)

        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = obj["oauth_token"] as? String, !token.isEmpty
        else {
            lastError = "Handoff file was present but unreadable; discarded."
            return nil
        }
        let handoff = Handoff(
            oauthToken: token,
            domain: obj["domain"] as? String ?? "accounts.google.com",
            capturedAt: (obj["capturedAt"] as? String).flatMap(Self.parseDate) ?? Date(),
            channel: "appgroup"
        )
        pending = handoff
        lastError = nil
        return handoff
    }

    /// Ingest the probe-only `gpmcprobe://token?value=…` URL.
    @discardableResult
    func ingest(url: URL) -> Handoff? {
        guard url.scheme == "gpmcprobe", url.host == "token",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "value" })?.value,
              !value.isEmpty
        else {
            lastError = "Unrecognised handoff URL."
            return nil
        }
        let capturedAt = comps.queryItems?
            .first(where: { $0.name == "capturedAt" })?.value
            .flatMap(Self.parseDate) ?? Date()
        let handoff = Handoff(oauthToken: value, domain: "accounts.google.com",
                              capturedAt: capturedAt, channel: "url")
        pending = handoff
        lastError = nil
        return handoff
    }

    /// Call once the exchange has finished with the token (success or failure).
    func consume() {
        pending = nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
