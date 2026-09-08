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
/// Two inbound channels, and which one is primary depends on how the build is
/// signed:
///   - App Group file, written by `SafariWebExtensionHandler`. Preferred, but
///     the entitlement needs a **paid** team — a free personal team cannot
///     provision App Groups at all.
///   - `photosbackup://token?value=…` URL. The fallback, and therefore the *only*
///     channel on a free-account sideload (SideStore / AltStore).
///
/// The URL channel carries a live single-use `oauth_token` through a custom
/// scheme, and iOS does not make scheme registration exclusive: another
/// installed app registering `photosbackup` could receive it instead. That is an
/// accepted risk for a personally sideloaded build, not a good idea for general
/// distribution — see docs/ADR-001-auth-route.md.
///
/// The token is held in memory just long enough for the exchange to run; the
/// source (file or nothing) is cleared immediately on read.
@MainActor
final class HandoffStore: ObservableObject {
    static let appGroupID = "group.com.g8row.photosbackup"
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

    /// Ingest the `photosbackup://token?value=…` URL handoff.
    @discardableResult
    func ingest(url: URL) -> Handoff? {
        guard url.scheme == "photosbackup", url.host == "token",
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

    /// The signed App Group flow opens this lightweight URL only to bring the
    /// containing app to the foreground; the actual credential remains in the
    /// protected handoff file and is drained once the scene becomes active.
    func isReturnURL(_ url: URL) -> Bool {
        url.scheme == "photosbackup" && url.host == "return"
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
