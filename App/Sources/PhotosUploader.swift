import Foundation

/// The one real `UploadWorker`: export the item to a file, hand it to
/// `GPMCClient`, delete the file whatever happens.
///
/// Kept separate from `UploadQueue` so the queue's state machine can be tested
/// with a stub worker and no photo library, network or credential in sight.
struct PhotosUploader {
    let exporter: MediaExporter
    /// Resolved per item rather than captured, so a reconnect swaps the client
    /// under a queue that is already running.
    let client: @Sendable () async -> GPMCClient?

    func worker() -> UploadWorker {
        let exporter = self.exporter
        let client = self.client
        return { source, options, emit in
            guard let client = await client() else {
                throw GPMCError(kind: .credentialRejected, message: "No Google account is connected. Connect one and try again.")
            }
            emit(.state(.exporting))
            let media = try await exporter.export(source)
            defer { Task { await exporter.discard(media) } }
            emit(.described(name: media.filename, byteCount: media.byteCount))
            try Task.checkCancellation()
            return try await client.upload(file: media.url, filename: media.filename, modified: media.modified,
                                           useQuota: options.useQuota, saver: options.storageSaver) { phase in
                emit(.state(phase.itemState))
            }
        }
    }
}

extension UploadPhase {
    /// Byte-level client progress mapped onto the row states the activity list shows.
    var itemState: UploadItem.State {
        switch self {
        case .hashing(let fraction): return .hashing(fraction: fraction)
        case .checkingDuplicate: return .checkingDuplicate
        case .preparing: return .uploading(fraction: 0)
        case .sending(let sent, let total): return .uploading(fraction: total > 0 ? min(1, Double(sent) / Double(total)) : 0)
        case .finalizing: return .finalizing
        }
    }
}
