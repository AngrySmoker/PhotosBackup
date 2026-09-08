import Foundation
import SafariServices
import os.log

/// Native endpoint for `browser.runtime.sendNativeMessage` from the web extension.
///
/// Runs in the *extension* process, which shares nothing with the containing
/// app except an App Group container. So the job here is narrow: validate the
/// incoming token, drop it into the App Group as a single-use, timestamped
/// file, and report back which channel was used.
///
/// If no App Group is available — an unsigned build, or any build signed by a
/// free personal team, which cannot provision the entitlement — it returns
/// `channel: "none"` plus the raw token so the popup can fall back to the
/// `photosbackup://` URL handoff. On a free-account sideload that fallback is the
/// only channel there is.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = "group.com.g8row.photosbackup"
    private static let handoffFilename = "handoff.json"
    private let log = OSLog(subsystem: "com.g8row.photosbackup.extension", category: "handoff")

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = messageBody(from: request)

        os_log("native message received: keys=%{public}@",
               log: log, type: .info,
               String(describing: (message as? [String: Any])?.keys.map { $0 } ?? []))

        let reply = NSExtensionItem()
        reply.userInfo = [messageKey: handle(message)]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }

    // MARK: - Core

    private func handle(_ message: Any?) -> [String: Any] {
        guard
            let dict = message as? [String: Any],
            (dict["type"] as? String) == "oauth_token",
            let value = (dict["value"] as? String), !value.isEmpty
        else {
            return ["ok": false, "reason": "malformed-message"]
        }

        let record: [String: Any] = [
            "oauth_token": value,
            "domain": dict["domain"] as? String ?? "accounts.google.com",
            "capturedAt": dict["capturedAt"] as? String ?? ISO8601DateFormatter().string(from: Date()),
            "source": dict["source"] as? String ?? "EmbeddedSetup",
            "consumed": false,
        ]

        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
        else {
            os_log("no App Group container — returning raw token for URL handoff",
                   log: log, type: .default)
            return [
                "ok": true,
                "channel": "none",
                "token": value,
                "note": "App Group unavailable (unsigned build); use URL handoff.",
            ]
        }

        let url = container.appendingPathComponent(Self.handoffFilename)
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            os_log("wrote handoff to App Group container", log: log, type: .info)
            return ["ok": true, "channel": "appgroup", "path": url.lastPathComponent]
        } catch {
            os_log("failed writing handoff: %{public}@", log: log, type: .error, String(describing: error))
            return ["ok": false, "reason": "write-failed", "detail": String(describing: error)]
        }
    }

    // MARK: - Message plumbing (Safari passes the body under different keys by OS version)

    private var messageKey: String {
        if #available(iOS 17.0, macOS 14.0, *) { return SFExtensionMessageKey }
        return "message"
    }

    private func messageBody(from item: NSExtensionItem?) -> Any? {
        guard let info = item?.userInfo else { return nil }
        return info[messageKey] ?? info["message"] ?? info[SFExtensionMessageKey]
    }
}
