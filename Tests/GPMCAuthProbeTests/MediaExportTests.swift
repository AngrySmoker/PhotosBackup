import XCTest
@testable import GPMCAuthProbe

/// Only the file-backed paths are exercised here — the `PHAsset` and
/// `PhotosPickerItem` paths need a real photo library and a user tap, so they
/// stay out of the offline suite.
final class MediaExportTests: XCTestCase {

    private func scratch(_ contents: Data, named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    func testExportingAnExistingFileKeepsItsNameSizeAndDate() async throws {
        let url = try scratch(Data(repeating: 7, count: 2048), named: "IMG_4242.HEIC")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)

        let media = try await MediaExporter().export(.file(url))
        XCTAssertEqual(media.filename, "IMG_4242.HEIC")
        XCTAssertEqual(media.byteCount, 2048)
        XCTAssertEqual(media.modified.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(media.temporary, "a file we did not stage is not ours to delete")
    }

    func testDiscardNeverDeletesAFileTheExporterDoesNotOwn() async throws {
        let url = try scratch(Data(repeating: 1, count: 16), named: "keep.jpg")
        let exporter = MediaExporter()
        let media = try await exporter.export(.file(url))
        await exporter.discard(media)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnEmptyFileIsRefusedBeforeItReachesTheUploader() async throws {
        let url = try scratch(Data(), named: "empty.jpg")
        do {
            _ = try await MediaExporter().export(.file(url))
            XCTFail("expected an empty file to be refused")
        } catch let failure as MediaExporter.Failure {
            XCTAssertEqual(failure, .unreadable("the file is empty"))
        }
    }

    func testMissingFileFailsWithAReadableMessage() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope-\(UUID()).jpg")
        do {
            _ = try await MediaExporter().export(.file(missing))
            XCTFail("expected a missing file to be refused")
        } catch let failure as MediaExporter.Failure {
            XCTAssertEqual(failure, .unreadable("the file is empty"))
        } catch {
            XCTFail("expected MediaExporter.Failure, got \(error)")
        }
    }

    func testStagedCopiesLandUnderOneDirectoryAndPurgeClearsThem() async throws {
        let source = try scratch(Data(repeating: 9, count: 64), named: "IMG_0007.JPG")
        let staged = try MediaExporter.adopt(source)
        XCTAssertEqual(staged.lastPathComponent, "IMG_0007.JPG")
        XCTAssertTrue(staged.path.contains(MediaExporter.directoryName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        // Each staged item gets its own directory, so two copies of the same
        // filename do not collide.
        let second = try MediaExporter.adopt(source)
        XCTAssertNotEqual(staged.path, second.path)

        let exporter = MediaExporter()
        await exporter.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testDiscardRemovesAStagedItemAndItsDirectory() async throws {
        let source = try scratch(Data(repeating: 3, count: 32), named: "clip.mov")
        let staged = try MediaExporter.adopt(source)
        addTeardownBlock { await MediaExporter().purge() }
        let media = ExportedMedia(url: staged, filename: "clip.mov", modified: Date(), byteCount: 32, temporary: true)
        await MediaExporter().discard(media)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }
}
