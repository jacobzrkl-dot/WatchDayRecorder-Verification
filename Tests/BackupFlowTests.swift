import Foundation
import XCTest
@testable import WatchDayRecorder

final class BackupFlowTests: XCTestCase {
    @MainActor
    func testBackupRestoreAndDuplicateRestorePreserveAudioManifestAndNames() async throws {
        let fixture = try await BackupFixture()
        defer { fixture.cleanup() }
        await fixture.backup.create()
        let url = try XCTUnwrap(fixture.backup.backupURL, fixture.backup.errorMessage ?? "No backup")
        await fixture.target.restore(from: url)
        XCTAssertNil(fixture.target.errorMessage)
        XCTAssertEqual(fixture.targetLibrary.chunks.count, 1)
        XCTAssertEqual(fixture.targetLedger.manifests.first?.receiptStatus(for: fixture.targetLibrary.chunks), .complete)
        XCTAssertEqual(fixture.targetCatalog.title(for: fixture.sessionID), "会议原名")
        XCTAssertTrue(fixture.targetCatalog.isArchived(fixture.sessionID))
        try fixture.targetCatalog.rename(fixture.sessionID, title: "恢复后新名称")
        await fixture.target.restore(from: url)
        XCTAssertNil(fixture.target.errorMessage)
        XCTAssertEqual(fixture.targetLibrary.chunks.count, 1)
        XCTAssertEqual(fixture.targetCatalog.title(for: fixture.sessionID), "恢复后新名称")
        let restored = try XCTUnwrap(fixture.targetLibrary.chunks.first)
        XCTAssertEqual(try FileChecksum.sha256(of: fixture.targetLibrary.fileURL(for: restored)), restored.sha256)
    }

    @MainActor
    func testCorruptedBackupNeverStartsImporting() async throws {
        let fixture = try await BackupFixture()
        defer { fixture.cleanup() }
        await fixture.backup.create()
        let url = try XCTUnwrap(fixture.backup.backupURL)
        let chunk = try XCTUnwrap(fixture.library.chunks.first)
        try Data("damaged".utf8).write(to: url.appendingPathComponent(chunk.filename))
        await fixture.target.restore(from: url)
        XCTAssertNotNil(fixture.target.errorMessage)
        XCTAssertTrue(fixture.targetLibrary.chunks.isEmpty)
        XCTAssertTrue(fixture.library.containsVerifiedCopy(of: fixture.original))
    }

    @MainActor
    func testSymlinkInsideBackupIsRejectedWithoutFollowingIt() async throws {
        let fixture = try await BackupFixture()
        defer { fixture.cleanup() }
        await fixture.backup.create()
        let directory = try XCTUnwrap(fixture.backup.backupURL)
        let chunk = try XCTUnwrap(fixture.library.chunks.first)
        let audio = directory.appendingPathComponent(chunk.filename)
        try FileManager.default.removeItem(at: audio)
        let outside = fixture.library.fileURL(for: chunk)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: outside)
        await fixture.target.restore(from: directory)
        XCTAssertNotNil(fixture.target.errorMessage)
        XCTAssertTrue(fixture.targetLibrary.chunks.isEmpty)
        XCTAssertEqual(try FileChecksum.sha256(of: outside), chunk.sha256)
    }

    func testUnknownBackupVersionFailsBeforeImport() throws {
        let snapshot = RecordingBackupManifest(schema: 2, createdAt: Date(), chunks: [], sessions: [], catalog: [])
        XCTAssertThrowsError(try snapshot.validate())
    }
}

@MainActor
private final class BackupFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessionID = UUID()
    let library: PhoneRecordingLibrary
    let targetLibrary: PhoneRecordingLibrary
    let targetLedger: RecordingSessionLedger
    let targetCatalog: PhoneSessionCatalog
    let backup: PhoneBackupController
    let target: PhoneBackupController
    let original: RecordingChunk

    init() async throws {
        library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("Source"))
        let ledger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("SourceMeta"))
        let catalog = PhoneSessionCatalog(rootDirectory: root.appendingPathComponent("SourceMeta"))
        let source = root.appendingPathComponent("fixture.m4a")
        try AudioTestFixture.writeAAC(to: source)
        let bytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! NSNumber
        original = RecordingChunk(id: UUID(), sessionID: sessionID, sequence: 0, filename: "fixture.m4a",
            startedAt: Date(), duration: 1, byteCount: bytes.int64Value, sha256: try FileChecksum.sha256(of: source))
        targetLibrary = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("Target"))
        targetLedger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("TargetMeta"))
        targetCatalog = PhoneSessionCatalog(rootDirectory: root.appendingPathComponent("TargetMeta"))
        backup = PhoneBackupController(library: library, ledger: ledger, catalog: catalog, outputRoot: root.appendingPathComponent("Backups"))
        target = PhoneBackupController(library: targetLibrary, ledger: targetLedger, catalog: targetCatalog)
        let result = await library.validateAndImport(stagedURL: source, source: original)
        guard result == .accepted else { throw BackupError.invalid }
        try ledger.begin(id: sessionID, at: original.startedAt)
        try ledger.register(original)
        try ledger.end(id: sessionID, needsRecovery: false)
        try catalog.rename(sessionID, title: "会议原名")
        try catalog.setArchived(sessionID, true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
