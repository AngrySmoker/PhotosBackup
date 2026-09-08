import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where one queued item came from. Everything reaches `GPMCClient.upload` as a
/// plain file on disk, so this is only ever a recipe for producing that file.
enum MediaSource: Equatable, Sendable {
    /// A `PHAsset` local identifier. Preferred: it carries the original
    /// filename and capture date, which a picker copy loses.
    case asset(localIdentifier: String)
    /// A picker selection we could not resolve to an asset (no library
    /// permission, or a cloud-only item chosen through the limited picker).
    case picked(PhotosPickerItem)
    /// An existing file. Used by tests and by anything that already staged one.
    case file(URL)
}

struct ExportedMedia: Equatable, Sendable {
    let url: URL
    let filename: String
    let modified: Date
    let byteCount: Int64
    /// False for `.file` sources, which the exporter does not own and must not delete.
    let temporary: Bool
}

/// Copies a picked item to disk without pulling it through memory.
/// `FileRepresentation` hands us a URL that is only valid inside the closure,
/// so the copy happens there and the caller gets a URL it owns.
private struct ImportedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { ImportedFile(url: try MediaExporter.adopt($0.file)) }
        FileRepresentation(importedContentType: .movie) { ImportedFile(url: try MediaExporter.adopt($0.file)) }
    }
}

/// Turns a `MediaSource` into a file `GPMCClient.upload` can read, and cleans
/// up after itself. Everything lands under one directory in Caches so a crash
/// leaves nothing the system will not reclaim.
actor MediaExporter {
    enum Failure: LocalizedError, Equatable {
        case missingAsset
        case noResource
        case unreadable(String)
        case liveOnly
        var errorDescription: String? {
            switch self {
            case .missingAsset: return "That item is no longer in your photo library."
            case .noResource: return "That item has no file to upload."
            case .liveOnly: return "That item is a Live Photo motion track, which this release does not upload."
            case .unreadable(let detail): return "Could not read that item: \(detail)"
            }
        }
    }

    static let directoryName = "gpmc-uploads"

    static var root: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Moves a system-owned temp file into our staging directory. Static so the
    /// `Transferable` closure, which runs wherever the system pleases, can use it.
    static func adopt(_ file: URL) throws -> URL {
        let destination = try stage(named: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func stage(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = name.isEmpty ? "item" : name
        return directory.appendingPathComponent(safe)
    }

    /// Delete anything left over from a previous run. Call once at launch.
    func purge() {
        try? FileManager.default.removeItem(at: Self.root)
    }

    func export(_ source: MediaSource) async throws -> ExportedMedia {
        switch source {
        case .file(let url):
            return try describe(url, filename: url.lastPathComponent, modified: nil, temporary: false)
        case .asset(let identifier):
            return try await exportAsset(identifier)
        case .picked(let item):
            // A picker item that carries a library identifier still has its
            // original filename and capture date; take that path when we can.
            if let identifier = item.itemIdentifier, let media = try? await exportAsset(identifier) { return media }
            guard let imported = try await item.loadTransferable(type: ImportedFile.self) else {
                throw Failure.noResource
            }
            return try describe(imported.url, filename: imported.url.lastPathComponent, modified: nil, temporary: true)
        }
    }

    /// Remove a staged file once the queue is finished with it.
    func discard(_ media: ExportedMedia) {
        guard media.temporary else { return }
        try? FileManager.default.removeItem(at: media.url.deletingLastPathComponent())
    }

    private func exportAsset(_ identifier: String) async throws -> ExportedMedia {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw Failure.missingAsset
        }
        let resources = PHAssetResource.assetResources(for: asset)
        // `.pairedVideo` / `.fullSizePairedVideo` are the Live Photo motion
        // track. Live Photos are a follow-up (ADR-001), so only the still or the
        // plain video is uploaded here.
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        guard let resource = preferred.compactMap({ type in resources.first { $0.type == type } }).first else {
            throw resources.isEmpty ? Failure.noResource : Failure.liveOnly
        }
        let destination = try Self.stage(named: resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw Failure.unreadable(error.localizedDescription)
        }
        return try describe(destination, filename: resource.originalFilename,
                            modified: asset.creationDate ?? asset.modificationDate, temporary: true)
    }

    private func describe(_ url: URL, filename: String, modified: Date?, temporary: Bool) throws -> ExportedMedia {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        guard size > 0 else { throw Failure.unreadable("the file is empty") }
        return ExportedMedia(url: url, filename: filename.isEmpty ? url.lastPathComponent : filename,
                             modified: modified ?? values?.contentModificationDate ?? Date(),
                             byteCount: size, temporary: temporary)
    }
}

/// Photo library permission, kept separate so the picker can be used without it
/// and the asset path can simply be skipped when it is not granted.
enum MediaLibrary {
    static var isReadable: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    @discardableResult
    static func requestReadAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Prefer asset identifiers so filenames and capture dates survive; fall
    /// back to the picker item itself when the library is off limits.
    static func sources(for items: [PhotosPickerItem]) -> [MediaSource] {
        let readable = isReadable
        return items.map { item in
            if readable, let identifier = item.itemIdentifier { return .asset(localIdentifier: identifier) }
            return .picked(item)
        }
    }
}

extension PHAssetResourceManager {
    func writeData(for resource: PHAssetResource, toFile url: URL, options: PHAssetResourceRequestOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
