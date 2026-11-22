import Foundation
import XCTest
@testable import WatchDayRecorder

final class PhoneStorageControllerTests: XCTestCase {
    @MainActor
    func testBackupCleanupRefusesAliasIntoOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = originals.appendingPathComponent("keep.m4a")
        try Data([1, 2]).write(to: source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("RecordingBackups"), withDestinationURL: originals)
        let controller = PhoneStorageController(recordingsDirectory: originals, temporaryDirectory: root)
        XCTAssertThrowsError(try controller.clearExpiredBackupCopies())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testBackupCleanupOnlyRemovesOldGeneratedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backups = root.appendingPathComponent("RecordingBackups")
        let old = backups.appendingPathComponent("全天录音备份_\(UUID())")
        let fresh = backups.appendingPathComponent("全天录音备份_\(UUID())")
        let foreign = backups.appendingPathComponent("user-directory")
        for url in [old, fresh, foreign] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let now = Date()
        for url in [old, foreign] { try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: url.path) }
        let controller = PhoneStorageController(recordingsDirectory: root.appendingPathComponent("Originals"), temporaryDirectory: root)
        XCTAssertEqual(try controller.clearExpiredBackupCopies(now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    @MainActor
    func testCleanupRefusesExportDirectorySymlinkToOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let original = recordings.appendingPathComponent("录音_important.m4a")
        try Data([1, 2, 3]).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: original.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("SessionExports"), withDestinationURL: recordings)
        let controller = PhoneStorageController(recordingsDirectory: recordings, temporaryDirectory: root)
        XCTAssertThrowsError(try controller.clearExpiredExports())
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    @MainActor
    func testCleanupRemovesOnlyOldOwnedExportFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("Recordings")
        let exports = root.appendingPathComponent("SessionExports")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let source = recordings.appendingPathComponent("录音_source.m4a")
        let old = exports.appendingPathComponent("录音_old.m4a")
        let fresh = exports.appendingPathComponent("录音_fresh.m4a")
        let unrelated = exports.appendingPathComponent("unrelated.m4a")
        let now = Date()
        for url in [source, old, fresh, unrelated] { try Data([1, 2, 3]).write(to: url) }
        for url in [source, old, unrelated] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: url.path)
        }
        let controller = PhoneStorageController(recordingsDirectory: recordings, temporaryDirectory: root)
        XCTAssertEqual(try controller.clearExpiredExports(now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for url in [source, fresh, unrelated] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }
}
