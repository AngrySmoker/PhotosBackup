import Foundation
import Photos

enum BackupConnection: String, CaseIterable, Identifiable {
    case wifiOnly
    case wifiAndCellular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiOnly: return "Wi-Fi Only"
        case .wifiAndCellular: return "Wi-Fi & Cellular"
        }
    }

    var detail: String {
        switch self {
        case .wifiOnly: return "Wait for Wi-Fi before uploading"
        case .wifiAndCellular: return "Back up wherever you are"
        }
    }
}

@MainActor
final class BackupPreferences: ObservableObject {
    private enum Key {
        static let selectedAlbumIDs = "backup.selectedAlbumIDs"
        static let automaticBackup = "backup.automatic"
        static let connection = "backup.connection"
        static let completedOnboarding = "app.completedOnboarding"
        static let backedUpCount = "backup.completedCount"
    }

    @Published var selectedAlbumIDs: Set<String> { didSet { saveAlbumIDs() } }
    @Published var automaticBackup: Bool { didSet { defaults.set(automaticBackup, forKey: Key.automaticBackup) } }
    @Published var connection: BackupConnection { didSet { defaults.set(connection.rawValue, forKey: Key.connection) } }
    @Published var completedOnboarding: Bool { didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) } }
    @Published private(set) var backedUpCount: Int

    private let defaults: UserDefaults
    private var countedQueueItems: Set<UUID> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedAlbumIDs = Set(defaults.stringArray(forKey: Key.selectedAlbumIDs) ?? [])
        automaticBackup = defaults.object(forKey: Key.automaticBackup) as? Bool ?? true
        connection = BackupConnection(rawValue: defaults.string(forKey: Key.connection) ?? "") ?? .wifiOnly
        completedOnboarding = defaults.bool(forKey: Key.completedOnboarding)
        backedUpCount = defaults.integer(forKey: Key.backedUpCount)
    }

    func toggle(albumID: String) {
        if selectedAlbumIDs.contains(albumID) { selectedAlbumIDs.remove(albumID) }
        else { selectedAlbumIDs.insert(albumID) }
    }

    func observeCompletedUploads(_ items: [UploadItem]) {
        let completed = items.filter { $0.state == .done || $0.state == .alreadyBackedUp }
        let newIDs = Set(completed.map(\.id)).subtracting(countedQueueItems)
        guard !newIDs.isEmpty else { return }
        countedQueueItems.formUnion(newIDs)
        backedUpCount += newIDs.count
        defaults.set(backedUpCount, forKey: Key.backedUpCount)
    }

    func resetOnboarding() { completedOnboarding = false }

    private func saveAlbumIDs() {
        defaults.set(Array(selectedAlbumIDs).sorted(), forKey: Key.selectedAlbumIDs)
    }
}

struct PhotoAlbum: Identifiable, Equatable {
    let id: String
    let title: String
    let count: Int
    let symbol: String
    let collection: PHAssetCollection

    static func == (lhs: PhotoAlbum, rhs: PhotoAlbum) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.count == rhs.count
    }
}

@MainActor
final class PhotoAlbumStore: ObservableObject {
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var isLoading = false

    var canRead: Bool { authorization == .authorized || authorization == .limited }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead { refresh() }
    }

    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard canRead else { albums = []; return }
        isLoading = true

        var result: [PhotoAlbum] = []
        var seen = Set<String>()
        func append(_ collection: PHAssetCollection) {
            guard seen.insert(collection.localIdentifier).inserted else { return }
            let fetch = PHAsset.fetchAssets(in: collection, options: nil)
            guard fetch.count > 0 else { return }
            result.append(PhotoAlbum(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Untitled Album",
                count: fetch.count,
                symbol: Self.symbol(for: collection),
                collection: collection
            ))
        }

        let smart = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smart.enumerateObjects { collection, _, _ in append(collection) }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        user.enumerateObjects { collection, _, _ in append(collection) }

        albums = result.sorted { lhs, rhs in
            if lhs.symbol == "camera.fill" { return true }
            if rhs.symbol == "camera.fill" { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        isLoading = false
    }

    func sources(for albumIDs: Set<String>) -> [MediaSource] {
        albums.filter { albumIDs.contains($0.id) }.flatMap { album in
            let assets = PHAsset.fetchAssets(in: album.collection, options: nil)
            var sources: [MediaSource] = []
            assets.enumerateObjects { asset, _, _ in
                sources.append(.asset(localIdentifier: asset.localIdentifier))
            }
            return sources
        }
    }

    static func symbol(for collection: PHAssetCollection) -> String {
        switch collection.assetCollectionSubtype {
        case .smartAlbumUserLibrary: return "camera.fill"
        case .smartAlbumScreenshots: return "iphone"
        case .smartAlbumSelfPortraits: return "person.crop.square"
        case .smartAlbumFavorites: return "heart.fill"
        case .smartAlbumVideos: return "video.fill"
        case .smartAlbumLivePhotos: return "livephoto"
        case .smartAlbumRecentlyAdded: return "clock.fill"
        default: return "rectangle.stack.fill"
        }
    }
}
