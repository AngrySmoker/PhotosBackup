import Foundation
import Photos

/// Persists PhotoKit's change token so automatic backup sees imports by library
/// insertion, including files whose embedded creation date is years old.
@MainActor
final class PhotoLibraryChangeTracker {
    struct Scan {
        let sources: [MediaSource]
        fileprivate let nextState: StoredState?
    }

    fileprivate struct StoredState: Codable {
        let context: String
        let token: Data
    }

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("photo-library-change-token-v1.json")
        }
    }

    func scan(albums: PhotoAlbumStore, selectedAlbumIDs: Set<String>, accountIdentifier: String?) -> Scan {
        let context = ([accountIdentifier?.lowercased() ?? ""] + selectedAlbumIDs.sorted())
            .joined(separator: "\u{1F}")
        guard #available(iOS 16, *) else {
            return Scan(sources: albums.sources(for: selectedAlbumIDs), nextState: nil)
        }

        let library = PHPhotoLibrary.shared()
        let current = library.currentChangeToken
        let next = archive(current).map { StoredState(context: context, token: $0) }
        guard let stored = load(), stored.context == context,
              let token = unarchive(stored.token) else {
            return Scan(sources: albums.sources(for: selectedAlbumIDs), nextState: next)
        }

        do {
            let changes = try library.fetchPersistentChanges(since: token)
            var identifiers = Set<String>()
            var selectedCollectionChanged = false
            for change in changes {
                let assetDetails = try change.changeDetails(for: .asset)
                identifiers.formUnion(assetDetails.insertedLocalIdentifiers)
                identifiers.formUnion(assetDetails.updatedLocalIdentifiers)
                if !selectedAlbumIDs.contains(PhotoAlbum.allPhotosID) {
                    let collectionDetails = try change.changeDetails(for: .assetCollection)
                    let changedCollections = collectionDetails.insertedLocalIdentifiers
                        .union(collectionDetails.updatedLocalIdentifiers)
                    if !selectedAlbumIDs.isDisjoint(with: changedCollections) {
                        selectedCollectionChanged = true
                    }
                }
            }
            let sources = selectedCollectionChanged
                ? albums.sources(for: selectedAlbumIDs)
                : albums.sources(for: selectedAlbumIDs, matching: identifiers)
            return Scan(sources: sources, nextState: next)
        } catch {
            // Expired/unavailable history requires one correctness-first current
            // scan, after which the fresh token becomes the new baseline.
            return Scan(sources: albums.sources(for: selectedAlbumIDs), nextState: next)
        }
    }

    /// Advance only after every source was handed to the durable queue.
    func commit(_ scan: Scan) {
        guard let state = scan.nextState else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            // Keeping the prior token causes harmless re-enqueue attempts; the
            // queue's durable asset-key ledger removes duplicates.
        }
    }

    func reset() { try? FileManager.default.removeItem(at: url) }

    private func load() -> StoredState? {
        try? JSONDecoder().decode(StoredState.self, from: Data(contentsOf: url))
    }

    @available(iOS 16, *)
    private func archive(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    @available(iOS 16, *)
    private func unarchive(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }
}
