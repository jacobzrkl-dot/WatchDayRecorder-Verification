import Foundation
import XCTest
@testable import WatchDayRecorder

final class ChunkSafetyTests: XCTestCase {
    @MainActor
    func testRecoveryAdoptsUntrackedFinalFileWithoutOverwritingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChunkQueueStore(rootDirectory: root)
        let sessionID = UUID()
        let chunkID = UUID()
        let url = store.recordingsDirectory.appendingPathComponent("\(sessionID)_0_\(chunkID).m4a")
        let original = Data(repeating: 7, count: 2_048)
        try original.write(to: url)
        XCTAssertEqual(try store.recoveryCandidates().count, 1)
        let recovered = try store.finalize(partialURL: url, chunkID: chunkID,
            sessionID: sessionID, sequence: 0, startedAt: Date(), duration: 10)
        XCTAssertEqual(recovered.id, chunkID)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(try store.recoveryCandidates().isEmpty)
    }

    func testUnreadableIndexMustNotBecomeAnEmptyLibrary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("index.json")
        try Data("invalid".utf8).write(to: url)
        let file = AtomicJSONFile<[String]>(url: url)
        XCTAssertThrowsError(try file.loadIfPresent(default: []))
        XCTAssertEqual(try Data(contentsOf: url), Data("invalid".utf8))
    }

    @MainActor
    func testCorruptWatchIndexIsPreservedOnLaunch() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chunk-queue.json")
        let original = Data("damaged index retained".utf8)
        try original.write(to: url)

        let store = ChunkQueueStore(rootDirectory: root)

        XCTAssertNotNil(store.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor
    func testUnavailableWatchAudioKeepsItsQueueRecord() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = sampleChunk(filename: "temporarily-unavailable.m4a")
        try AtomicJSONFile<[RecordingChunk]>(
            url: root.appendingPathComponent("chunk-queue.json")
        ).save([chunk])
        let store = ChunkQueueStore(rootDirectory: root)
        XCTAssertEqual(store.chunks.map(\.id), [chunk.id])
        XCTAssertEqual(store.chunks.first?.state, .failed)
    }

    func testSequenceMustStartAtZeroAndContainNoGaps() {
        XCTAssertTrue(ChunkSequenceValidator.isContinuous([0, 1, 2, 3]))
        XCTAssertFalse(ChunkSequenceValidator.isContinuous([1, 2, 3]))
        XCTAssertFalse(ChunkSequenceValidator.isContinuous([0, 1, 3]))
        XCTAssertFalse(ChunkSequenceValidator.isContinuous([0, 1, 1, 2]))
    }

    func testDurationValidationRejectsTruncatedLongChunk() {
        XCTAssertTrue(
            RecordingDurationValidator.isPlausible(
                expected: 600,
                actual: 598
            )
        )
        XCTAssertFalse(
            RecordingDurationValidator.isPlausible(
                expected: 600,
                actual: 480
            )
        )
        XCTAssertFalse(
            RecordingDurationValidator.isPlausible(
                expected: 10,
                actual: 6
            )
        )
    }

    func testAtomicJSONFallsBackToLastKnownGoodBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let file = AtomicJSONFile<[String]>(url: url)

        try file.save(["safe"])
        try Data("not-json".utf8).write(to: url, options: .atomic)

        XCTAssertEqual(file.load(default: []), ["safe"])
    }

    @MainActor
    func testRelaunchFinishesMoveForPersistedChunk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunksDirectory = root.appendingPathComponent("Chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        let chunk = sampleChunk(filename: "session_0_chunk.m4a")
        let partialURL = chunksDirectory.appendingPathComponent("session_0_chunk.partial.m4a")
        try Data(repeating: 7, count: 2_048).write(to: partialURL)
        try AtomicJSONFile<[RecordingChunk]>(
            url: root.appendingPathComponent("chunk-queue.json")
        ).save([chunk])

        let store = ChunkQueueStore(rootDirectory: root)

        XCTAssertEqual(store.chunks.map(\.id), [chunk.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(for: chunk).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    @MainActor
    func testAcknowledgementTimeoutStartsWhenTransferFinishes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = sampleChunk(
            filename: "chunk.m4a",
            lastAttemptAt: Date(timeIntervalSince1970: 10)
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Chunks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 2_048).write(
            to: root.appendingPathComponent("Chunks/chunk.m4a")
        )
        try AtomicJSONFile<[RecordingChunk]>(
            url: root.appendingPathComponent("chunk-queue.json")
        ).save([chunk])
        let store = ChunkQueueStore(rootDirectory: root)
        let deliveredAt = Date(timeIntervalSince1970: 2_000)

        store.markAwaitingAcknowledgement(chunk.id, at: deliveredAt)

        XCTAssertEqual(store.chunks.first?.lastAttemptAt, deliveredAt)
    }

    @MainActor
    func testMismatchedAcknowledgementNeverDeletesWatchSource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = sampleChunk(filename: "chunk.m4a")
        let chunksDirectory = root.appendingPathComponent("Chunks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: chunksDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = chunksDirectory.appendingPathComponent(chunk.filename)
        try Data(repeating: 9, count: 2_048).write(to: sourceURL)
        try AtomicJSONFile<[RecordingChunk]>(
            url: root.appendingPathComponent("chunk-queue.json")
        ).save([chunk])
        let store = ChunkQueueStore(rootDirectory: root)

        XCTAssertThrowsError(
            try store.removeAfterAcknowledgement(
                id: chunk.id,
                sha256: String(repeating: "f", count: 64)
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(store.chunks.map(\.id), [chunk.id])
    }

    private func sampleChunk(
        filename: String,
        lastAttemptAt: Date? = nil
    ) -> RecordingChunk {
        RecordingChunk(
            id: UUID(),
            sessionID: UUID(),
            sequence: 0,
            filename: filename,
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 10,
            byteCount: 2_048,
            sha256: String(repeating: "a", count: 64),
            lastAttemptAt: lastAttemptAt
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchDayRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
