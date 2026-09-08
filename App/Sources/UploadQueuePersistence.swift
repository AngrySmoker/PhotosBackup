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

/// Durable hand-off between export, background PUT, and commit. A checkpoint
/// without `prepared` resumes preflight; one with a nil receipt reattaches to
/// the background task; one with a receipt skips straight to commit.
struct UploadCheckpoint: Codable, Equatable, Sendable {
    let filePath: String
    let filename: String
    let modified: Date
    let byteCount: Int64
    let temporary: Bool
    var prepared: PreparedUpload?
    var continuesAfterProcessExit: Bool? = nil

    var fileURL: URL { URL(fileURLWithPath: filePath) }
    var isBackgroundTransfer: Bool { prepared != nil && continuesAfterProcessExit == true }
}

struct PersistedUploadItem: Codable, Equatable, Sendable {
    let id: UUID
    let source: PersistedMediaSource
    let name: String
    let byteCount: Int64
    let attempts: Int
    let failureReason: String?
    let failureRetryable: Bool
    let checkpoint: UploadCheckpoint?

    init(id: UUID, source: PersistedMediaSource, name: String, byteCount: Int64,
         attempts: Int, failureReason: String?, failureRetryable: Bool,
         checkpoint: UploadCheckpoint? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.byteCount = byteCount
        self.attempts = attempts
        self.failureReason = failureReason
        self.failureRetryable = failureRetryable
        self.checkpoint = checkpoint
    }
}

struct UploadQueueSnapshot: Codable, Equatable, Sendable {
    static let version = 1

    let version: Int
    let accountIdentifier: String
    let items: [PersistedUploadItem]
    let completedSourceKeys: [String]
    /// Optional so snapshots written by earlier releases remain decodable.
    let isUserPaused: Bool?

    init(version: Int, accountIdentifier: String, items: [PersistedUploadItem],
         completedSourceKeys: [String], isUserPaused: Bool? = nil) {
        self.version = version
        self.accountIdentifier = accountIdentifier
        self.items = items
        self.completedSourceKeys = completedSourceKeys
        self.isUserPaused = isUserPaused
    }
}

protocol UploadQueuePersisting {
    func load() throws -> UploadQueueSnapshot?
    func save(_ snapshot: UploadQueueSnapshot) throws
    var storesCompletionLedgerSeparately: Bool { get }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String]
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws
}

extension UploadQueuePersisting {
    var storesCompletionLedgerSeparately: Bool { false }
    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        guard let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier else { return [] }
        return snapshot.completedSourceKeys
    }
    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {}
}

/// Stores one account-scoped queue atomically in Application Support. The file
/// remains readable after the first device unlock so an iOS background task can
/// restore it while the phone is locked.
struct FileUploadQueuePersistence: UploadQueuePersisting {
    private let url: URL
    private let ledgerURL: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
            ledgerURL = url.deletingLastPathComponent().appendingPathComponent("completed-sources-v1.log")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("upload-queue-v1.json")
            ledgerURL = base.appendingPathComponent("PhotosBackup", isDirectory: true)
                .appendingPathComponent("completed-sources-v1.log")
        }
    }

    var storesCompletionLedgerSeparately: Bool { true }

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

    func loadCompletedSourceKeys(for accountIdentifier: String) throws -> [String] {
        var keys: [String] = []
        if let snapshot = try load(), snapshot.accountIdentifier == accountIdentifier {
            keys.append(contentsOf: snapshot.completedSourceKeys)
        }
        guard FileManager.default.fileExists(atPath: ledgerURL.path) else { return keys }
        let account = Data(accountIdentifier.utf8).base64EncodedString()
        let contents = try String(contentsOf: ledgerURL, encoding: .utf8)
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(account),
                  let data = Data(base64Encoded: String(parts[1])) else { continue }
            keys.append(String(decoding: data, as: UTF8.self))
        }
        return keys
    }

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        let directory = ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: ledgerURL.path) {
            guard FileManager.default.createFile(atPath: ledgerURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let line = Data((Data(accountIdentifier.utf8).base64EncodedString() + "\t"
            + Data(key.utf8).base64EncodedString() + "\n").utf8)
        let handle = try FileHandle(forWritingTo: ledgerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: ledgerURL.path
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

    func recordCompletedSourceKey(_ key: String, for accountIdentifier: String) throws {
        guard let snapshot, snapshot.accountIdentifier == accountIdentifier,
              !snapshot.completedSourceKeys.contains(key) else { return }
        self.snapshot = UploadQueueSnapshot(version: snapshot.version,
                                            accountIdentifier: snapshot.accountIdentifier,
                                            items: snapshot.items,
                                            completedSourceKeys: snapshot.completedSourceKeys + [key],
                                            isUserPaused: snapshot.isUserPaused)
    }
}
