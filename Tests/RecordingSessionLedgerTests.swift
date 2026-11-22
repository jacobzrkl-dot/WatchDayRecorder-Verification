import Foundation
import XCTest
@testable import WatchDayRecorder

final class RecordingSessionLedgerTests: XCTestCase {
    @MainActor
    func testNewerManifestCannotDropPreviouslyDeclaredChunks() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        try ledger.register(chunk(id, sequence: 0))
        var incoming = try XCTUnwrap(ledger.manifests.first)
        incoming.revision += 1
        incoming.chunks = []
        XCTAssertThrowsError(try ledger.merge(incoming))
        XCTAssertEqual(ledger.manifests.first?.chunks.count, 1)
    }

    @MainActor
    func testNewerManifestCannotReopenClosedSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        try ledger.end(id: id, needsRecovery: false)
        var incoming = try XCTUnwrap(ledger.manifests.first)
        incoming.revision += 1
        incoming.endedAt = nil
        XCTAssertThrowsError(try ledger.merge(incoming))
        XCTAssertNotNil(ledger.manifests.first?.endedAt)
    }

    @MainActor
    func testSameRevisionCannotEraseInterruptionWarning() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        try ledger.end(id: id, needsRecovery: false, interrupted: true)
        var incoming = try XCTUnwrap(ledger.manifests.first)
        incoming.wasInterrupted = false
        XCTAssertThrowsError(try ledger.merge(incoming))
        XCTAssertEqual(ledger.manifests.first?.wasInterrupted, true)
    }

    @MainActor
    func testNewerManifestCannotEraseInterruptionWarning() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        try ledger.end(id: id, needsRecovery: false, interrupted: true)
        var incoming = try XCTUnwrap(ledger.manifests.first)
        incoming.revision += 1
        incoming.wasInterrupted = false
        XCTAssertThrowsError(try ledger.merge(incoming))
        XCTAssertEqual(ledger.manifests.first?.wasInterrupted, true)
    }

    @MainActor
    func testIdenticalManifestRedeliveryAfterRelaunchRemainsAccepted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date(timeIntervalSince1970: 1_700_000_000.875))
        try ledger.end(id: id, needsRecovery: false, interrupted: true)
        let original = try XCTUnwrap(ledger.manifests.first)
        let reloaded = RecordingSessionLedger(rootDirectory: root)
        // ISO8601 persistence rounds away fractional seconds; duplicate
        // protocol messages must remain idempotent across that boundary.
        XCTAssertNoThrow(try reloaded.merge(original))
    }

    @MainActor
    func testOpenSessionCannotCompleteBeforeEndConfirmation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        let first = chunk(id, sequence: 0)
        try ledger.begin(id: id, at: Date())
        try ledger.register(first)
        XCTAssertEqual(ledger.manifests.first?.receiptStatus(for: [received(first)]), .recording)
    }

    @MainActor
    func testInvalidDuplicateManifestIsRejectedWithoutBuildingDictionary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        try ledger.register(chunk(id, sequence: 0))
        var manifest = try XCTUnwrap(ledger.manifests.first)
        manifest.chunks.append(manifest.chunks[0])
        XCTAssertEqual(manifest.receiptStatus(for: []), .conflict)
        XCTAssertThrowsError(try ledger.merge(manifest))
    }

    @MainActor
    func testMissingLastChunkNeverCountsAsComplete() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        try ledger.begin(id: id, at: Date())
        let first = chunk(id, sequence: 0)
        let last = chunk(id, sequence: 1)
        try ledger.register(first)
        try ledger.register(last)
        try ledger.end(id: id, needsRecovery: false)
        let manifest = try XCTUnwrap(ledger.manifests.first)
        XCTAssertEqual(manifest.receiptStatus(for: [received(first)]), .awaitingChunks(received: 1, expected: 2))
        XCTAssertEqual(manifest.receiptStatus(for: [received(last), received(first)]), .complete)
    }

    @MainActor
    func testWrongHashAndExtraChunkCannotCompleteSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        let id = UUID()
        let first = chunk(id, sequence: 0)
        try ledger.begin(id: id, at: Date())
        try ledger.register(first)
        try ledger.end(id: id, needsRecovery: false)
        let manifest = try XCTUnwrap(ledger.manifests.first)
        XCTAssertEqual(manifest.receiptStatus(for: [received(first, hash: String(repeating: "f", count: 64))]), .conflict)
        XCTAssertEqual(manifest.receiptStatus(for: [received(first), received(chunk(id, sequence: 1))]), .conflict)
    }

    @MainActor
    func testStaleManifestCannotReopenEndedSession() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("watch"))
        let destination = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("phone"))
        let id = UUID()
        try source.begin(id: id, at: Date())
        let old = try XCTUnwrap(source.manifests.first)
        try source.end(id: id, needsRecovery: false)
        let closed = try XCTUnwrap(source.manifests.first)
        try destination.merge(closed)
        try destination.merge(old)
        XCTAssertEqual(destination.manifests.first?.revision, closed.revision)
        XCTAssertNotNil(destination.manifests.first?.endedAt)
        XCTAssertNotNil(RecordingSessionLedger(rootDirectory: root.appendingPathComponent("phone")).manifests.first?.endedAt)
    }

    @MainActor
    func testOpenSessionAfterRestartRequiresRecovery() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = RecordingSessionLedger(rootDirectory: root)
        try first.begin(id: UUID(), at: Date())
        let restarted = RecordingSessionLedger(rootDirectory: root)
        try restarted.interruptOpenSessions()
        XCTAssertEqual(restarted.manifests.first?.receiptStatus(for: []), .needsRecovery)
        XCTAssertEqual(restarted.manifests.first?.wasInterrupted, true)
    }

    @MainActor
    func testManifestProtocolAndAcknowledgementRoundTrip() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        try ledger.begin(id: UUID(), at: Date())
        let manifest = try XCTUnwrap(ledger.manifests.first)
        let decoded = try XCTUnwrap(TransferProtocol.parseManifest(try TransferProtocol.manifestPayload(manifest)))
        XCTAssertEqual(decoded, manifest)
        let ack = try XCTUnwrap(TransferProtocol.parseManifestAcknowledgement(TransferProtocol.manifestAcknowledgement(manifest)))
        XCTAssertEqual(ack.id, manifest.id)
        XCTAssertEqual(ack.revision, manifest.revision)
    }

    @MainActor
    func testSameRevisionWithDifferentContentsIsRejected() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = RecordingSessionLedger(rootDirectory: root)
        try ledger.begin(id: UUID(), at: Date())
        var manifest = try XCTUnwrap(ledger.manifests.first)
        manifest.requiresRecovery = true
        XCTAssertThrowsError(try ledger.merge(manifest))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func chunk(_ sessionID: UUID, sequence: Int) -> RecordingChunk {
        RecordingChunk(id: UUID(), sessionID: sessionID, sequence: sequence,
                       filename: "\(sequence).m4a", startedAt: Date(), duration: 600,
                       byteCount: 2_048, sha256: String(repeating: "a", count: 64))
    }

    private func received(_ chunk: RecordingChunk, hash: String? = nil) -> PhoneRecordingChunk {
        PhoneRecordingChunk(id: chunk.id, sessionID: chunk.sessionID, sequence: chunk.sequence,
                            filename: chunk.filename, startedAt: chunk.startedAt, duration: chunk.duration,
                            byteCount: chunk.byteCount, sha256: hash ?? chunk.sha256, receivedAt: Date())
    }
}
