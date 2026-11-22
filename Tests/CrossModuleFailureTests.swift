import Foundation
import XCTest
@testable import WatchDayRecorder

final class CrossModuleFailureTests: XCTestCase {
    func testDiagnosticsCanRefreshAfterClockRollsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionEvidenceStore(rootDirectory: root)
        let now = Date(), future = now.addingTimeInterval(86_400)
        func payload(_ date: Date) throws -> Data {
            let report = DiagnosticReport(schema: 1, generatedAt: date, platform: "Watch", appVersion: "test", context: [:], events: [], watch: nil)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(report)
        }
        try store.acceptDiagnostics(payload(future), now: future)
        try store.acceptDiagnostics(payload(now), now: now)
        XCTAssertTrue(RecordingMetadataValidation.sameSecond(try XCTUnwrap(store.diagnostics()).generatedAt, now))
        XCTAssertThrowsError(try store.acceptDiagnostics(payload(future), now: now))
    }

    @MainActor
    func testUnreadableIndexesCannotBeOverwrittenByPersistenceRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bad = Data("unreadable-original".utf8)
        for filename in ["chunk-queue.json", "chunk-queue.json.backup", "session-manifests.json", "session-manifests.json.backup"] {
            try bad.write(to: root.appendingPathComponent(filename))
        }
        let store = ChunkQueueStore(rootDirectory: root)
        let ledger = RecordingSessionLedger(rootDirectory: root)
        XCTAssertThrowsError(try store.retryPersistenceForRecovery())
        XCTAssertThrowsError(try ledger.retryPersistenceForRecovery())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("chunk-queue.json")), bad)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("session-manifests.json")), bad)
    }

    @MainActor
    func testRecoveryCanRetryQueuePersistenceAfterStorageReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChunkQueueStore(rootDirectory: root)
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID(), session = UUID()
        try ledger.begin(id: session, at: Date())
        let partial = store.partialURL(sessionID: session, sequence: 0, chunkID: id)
        try AudioTestFixture.writeAAC(to: partial)
        let index = root.appendingPathComponent("chunk-queue.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.finalize(partialURL: partial, chunkID: id, sessionID: session, sequence: 0, startedAt: Date(), duration: 1))
        XCTAssertNotNil(store.persistenceError)
        try FileManager.default.removeItem(at: index)
        let environment = RecorderEnvironment(makeDevice: { _, _ in throw BackupError.invalid }, configureSession: {}, activateSession: {},
            deactivateSession: {}, authorization: { .granted }, requestAuthorization: { _ in }, batteryLevel: { 1 }, feedback: { _ in })
        let recorder = ChunkedRecorder(store: store, ledger: ledger, environment: environment)
        let recovery = WatchRecoveryController(store: store, ledger: ledger, recorder: recorder, scheduleTransfers: {})
        await recovery.recover()
        XCTAssertTrue(recovery.failures.isEmpty)
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(store.recoveryFileCount, 0)
        XCTAssertEqual(ledger.manifests.first?.chunks.map(\.id), [id])
    }

    @MainActor
    func testRecoveryRetriesTransientLedgerFailureWithoutRecreatingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChunkQueueStore(rootDirectory: root.appendingPathComponent("Queue"))
        let ledgerRoot = root.appendingPathComponent("Ledger")
        let ledger = RecordingSessionLedger(rootDirectory: ledgerRoot)
        let chunk = try makeChunk(store)
        try ledger.begin(id: chunk.sessionID, at: chunk.startedAt)
        let index = ledgerRoot.appendingPathComponent("session-manifests.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ledger.register(chunk))
        XCTAssertNotNil(ledger.lastError)
        try FileManager.default.removeItem(at: index)
        let environment = RecorderEnvironment(makeDevice: { _, _ in throw BackupError.invalid },
            configureSession: {}, activateSession: {}, deactivateSession: {}, authorization: { .granted },
            requestAuthorization: { _ in }, batteryLevel: { 1 }, feedback: { _ in })
        let recorder = ChunkedRecorder(store: store, ledger: ledger, environment: environment)
        var scheduled = 0
        let recovery = WatchRecoveryController(store: store, ledger: ledger, recorder: recorder, scheduleTransfers: { scheduled += 1 })
        await recovery.recover()
        XCTAssertTrue(recovery.failures.isEmpty)
        XCTAssertEqual(ledger.manifests.first?.chunks.map(\.id), [chunk.id])
        XCTAssertNotNil(ledger.manifests.first?.endedAt)
        XCTAssertNil(ledger.lastError)
        XCTAssertEqual(scheduled, 1)
    }

    @MainActor
    func testAcknowledgementIndexFailureKeepsRawFileAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChunkQueueStore(rootDirectory: root)
        let chunk = try makeChunk(store)
        let index = root.appendingPathComponent("chunk-queue.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removeAfterAcknowledgement(id: chunk.id, sha256: chunk.sha256))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: chunk).path))
        XCTAssertEqual(store.chunks.map(\.id), [chunk.id])
        try FileManager.default.removeItem(at: index)
        try store.removeAfterAcknowledgement(id: chunk.id, sha256: chunk.sha256)
        XCTAssertTrue(ChunkQueueStore(rootDirectory: root).chunks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: chunk).path))
    }

    @MainActor
    func testAudioCleanupFailureRetainsRecoverableFileInsteadOfMissingAudioQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RejectAudioDeletion()
        let store = ChunkQueueStore(rootDirectory: root, fileManager: manager)
        let chunk = try makeChunk(store)
        manager.blocked = store.fileURL(for: chunk)
        XCTAssertThrowsError(try store.removeAfterAcknowledgement(id: chunk.id, sha256: chunk.sha256))
        XCTAssertTrue(store.chunks.isEmpty)
        XCTAssertEqual(store.recoveryFileCount, 1)
        let reopened = ChunkQueueStore(rootDirectory: root)
        XCTAssertTrue(reopened.chunks.isEmpty)
        XCTAssertEqual(try reopened.recoveryCandidates().map(\.lastPathComponent), [chunk.filename])
    }

    func testClockRollbackDoesNotPermanentlyBlockFreshStateOrAlert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), future = now.addingTimeInterval(86_400)
        let old = WatchCaptureStatus(timestamp: future, mode: .paused, pendingChunks: 0, battery: 1, error: nil)
        let fresh = WatchCaptureStatus(timestamp: now, mode: .paused, pendingChunks: 0, battery: 1, error: nil)
        XCTAssertTrue(try CompanionEvidenceStore(rootDirectory: root).save(old, now: future))
        let reopened = CompanionEvidenceStore(rootDirectory: root)
        XCTAssertTrue(try reopened.save(fresh, now: now))
        XCTAssertEqual(reopened.status()?.timestamp, now)
        XCTAssertTrue(fresh.shouldNotify(after: old, now: now))
        XCTAssertTrue(fresh.needsPublication(after: old))
        XCTAssertFalse(fresh.needsPublication(after: fresh))
    }

    @MainActor
    private func makeChunk(_ store: ChunkQueueStore) throws -> RecordingChunk {
        let id = UUID(), session = UUID()
        let url = store.partialURL(sessionID: session, sequence: 0, chunkID: id)
        try AudioTestFixture.writeAAC(to: url)
        return try store.finalize(partialURL: url, chunkID: id, sessionID: session, sequence: 0, startedAt: Date(), duration: 1)
    }
}

private final class RejectAudioDeletion: FileManager, @unchecked Sendable {
    var blocked: URL?
    override func removeItem(at url: URL) throws {
        if url == blocked { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
