import Foundation

/// The durable subset of a media source. Picker-only selections cannot be
/// reconstructed after process death, while library assets and file URLs can.
enum PersistedMediaSource: Codable, Equatable, Sendable {
    case asset(String)
    case file(String)

    init?(_ source: MediaSource) {
        switch source {
        case .asset(let identifier): self = .asset(identifier)
        case .file(let url): self = .file(url.standardizedFileURL.path)
        case .picked: return nil
        }
    }

    var mediaSource: MediaSource {
        switch self {
        case .asset(let identifier): return .asset(localIdentifier: identifier)
        case .file(let path): return .file(URL(fileURLWithPath: path))
        }
    }
}

struct PersistedUploadItem: Codable, Equatable, Sendable {
    let id: UUID
    let source: PersistedMediaSource
    let name: String
    let byteCount: Int64
    let attempts: Int
    let failureReason: String?
    let failureRetryable: Bool
}

struct UploadQueueSnapshot: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let accountIdentifier: String
    let items: [PersistedUploadItem]
    let completedSourceKeys: [String]
}

protocol UploadQueuePersisting {
    func load() throws -> UploadQueueSnapshot?
    func save(_ snapshot: UploadQueueSnapshot) throws
}

/// Stores one account-scoped queue atomically in Application Support. The file
/// remains readable after the first device unlock so an iOS background task can
/// restore it while the phone is locked.
struct FileUploadQueuePersistence: UploadQueuePersisting {
    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("upload-queue-v1.json")
        }
    }

    func load() throws -> UploadQueueSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(UploadQueueSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: UploadQueueSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }
}

final class MemoryUploadQueuePersistence: UploadQueuePersisting {
    var snapshot: UploadQueueSnapshot?

    init(snapshot: UploadQueueSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() throws -> UploadQueueSnapshot? { snapshot }
    func save(_ snapshot: UploadQueueSnapshot) throws { self.snapshot = snapshot }
}
