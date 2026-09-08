import Foundation

/// Composition root for the Google Photos side. Builds the account, the
/// exporter and the queue already wired to each other, so the app entry point
/// only has to hold on to two objects.
@MainActor
final class PhotosStack {
    let account: PhotosAccount
    let queue: UploadQueue
    private let exporter: MediaExporter

    init(store: CredentialStore = CredentialStore(), exporter: MediaExporter = MediaExporter()) {
        let account = PhotosAccount(store: store)
        let uploader = PhotosUploader(exporter: exporter) { await account.currentClient() }
        self.account = account
        self.exporter = exporter
        self.queue = UploadQueue(worker: uploader.worker())
        self.queue.onCredentialRejected = { [weak account] error in account?.report(error) }
    }

    /// Restore the saved account and sweep away temp files from a previous run.
    func start() async {
        await exporter.purge()
        await account.restore()
    }

    /// Hand a finished exchange to the account, then let the queue carry on.
    func connect(_ result: TokenExchange.Result) async {
        await account.connect(result)
        if account.status.isUsable { queue.resume() }
    }
}
