import Foundation

/// The one real `UploadWorker`: export the item to a file, hand it to
/// `GPMCClient`, and retain it across retry/relaunch boundaries until the
/// transfer commits or reaches a terminal state.
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
        return { id, source, restoredCheckpoint, options, emit in
            guard let client = await client() else {
                throw GPMCError(kind: .credentialRejected, message: "No Google account is connected. Connect one and try again.")
            }
            var checkpoint = restoredCheckpoint
            if let restoredCheckpoint,
               !FileManager.default.fileExists(atPath: restoredCheckpoint.filePath) {
                checkpoint = nil
                await emit(.checkpoint(nil))
            }
            if checkpoint == nil {
                await emit(.state(.exporting))
                let media = try await exporter.export(source, allowsNetworkAccess: options.allowsICloudDownload)
                checkpoint = UploadCheckpoint(
                    filePath: media.url.standardizedFileURL.path,
                    filename: media.filename,
                    modified: media.modified,
                    byteCount: media.byteCount,
                    temporary: media.temporary,
                    prepared: nil,
                    continuesAfterProcessExit: await client.usesBackgroundFileTransfers
                )
                await emit(.described(name: media.filename, byteCount: media.byteCount))
                await emit(.checkpoint(checkpoint))
            }
            guard var checkpoint else {
                throw GPMCError(message: "Could not stage the upload.")
            }
            try Task.checkCancellation()

            if checkpoint.prepared == nil {
                let preparation = try await client.prepareUpload(
                    file: checkpoint.fileURL,
                    filename: checkpoint.filename,
                    modified: checkpoint.modified,
                    useQuota: options.useQuota,
                    saver: options.storageSaver
                ) { phase in
                    Task { await emit(.state(phase.itemState)) }
                }
                switch preparation {
                case .alreadyBackedUp(let mediaKey):
                    await exporter.discard(checkpoint.exportedMedia)
                    await emit(.checkpoint(nil))
                    return .alreadyBackedUp(mediaKey: mediaKey)
                case .ready(let prepared):
                    checkpoint.prepared = prepared
                    // This write is the hand-off: after it returns, relaunch can
                    // safely find the body and reattach to the task by `id`.
                    await emit(.checkpoint(checkpoint))
                }
            }

            guard let prepared = checkpoint.prepared else {
                throw GPMCError(message: "Could not prepare the upload.")
            }
            let completed: PreparedUpload
            do {
                completed = try await client.transfer(prepared, file: checkpoint.fileURL, transferID: id) { phase in
                    Task { await emit(.state(phase.itemState)) }
                }
            } catch {
                await client.forgetTransfer(id)
                // A failed upload URL may no longer be reusable. Keep the
                // expensive staged body, but obtain a fresh upload ID on retry.
                checkpoint.prepared = nil
                await emit(.checkpoint(checkpoint))
                throw error
            }
            checkpoint.prepared = completed
            await emit(.checkpoint(checkpoint))

            let outcome = try await client.commit(completed) { phase in
                Task { await emit(.state(phase.itemState)) }
            }
            await client.forgetTransfer(id)
            await exporter.discard(checkpoint.exportedMedia)
            await emit(.checkpoint(nil))
            return outcome
        }
    }

    func checkpointCleaner() -> UploadCheckpointCleaner {
        let exporter = self.exporter
        let client = self.client
        return { id, checkpoint in
            if let client = await client() { await client.cancelTransfer(id) }
            else { await BackgroundFileUploadTransport.shared.cancel(transferID: id) }
            await exporter.discard(checkpoint.exportedMedia)
        }
    }
}

private extension UploadCheckpoint {
    var exportedMedia: ExportedMedia {
        ExportedMedia(url: fileURL, filename: filename, modified: modified,
                      byteCount: byteCount, temporary: temporary)
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
