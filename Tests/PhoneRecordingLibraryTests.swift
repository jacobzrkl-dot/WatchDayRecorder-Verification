import AVFoundation
import Foundation
import XCTest
@testable import WatchDayRecorder

private final class CorruptingImportCopyManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        try super.copyItem(at: source, to: destination)
        if destination.lastPathComponent.contains(".importing-") {
            try Data([0, 1, 2]).write(to: destination)
        }
    }
}

final class PhoneRecordingLibraryTests: XCTestCase {
    @MainActor
    func testCorruptedCopyCannotBeIndexedOrAcknowledged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.m4a")
        try AudioTestFixture.writeAAC(to: source)
        let bytes = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as! NSNumber
        let chunk = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0, filename: "source.m4a",
            startedAt: Date(), duration: 1, byteCount: bytes.int64Value, sha256: try FileChecksum.sha256(of: source))
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"), fileManager: CorruptingImportCopyManager())
        let result = await library.validateAndImport(stagedURL: source, source: chunk)
        if case .rejected = result {} else { XCTFail("A corrupted destination copy must be rejected") }
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertEqual(try FileChecksum.sha256(of: source), chunk.sha256)
    }

    @MainActor
    func testIntegrityCheckDetectsSameSizeDamageAndPersistsUntilRepaired() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let appRoot = root.appendingPathComponent("App")
        let library = PhoneRecordingLibrary(rootDirectory: appRoot)
        let result = await library.validateAndImport(stagedURL: source.url, source: source.chunk)
        XCTAssertEqual(result, .accepted)
        let chunk = try XCTUnwrap(library.chunks.first)
        let local = library.fileURL(for: chunk)
        try Data(repeating: 0x7f, count: Int(chunk.byteCount)).write(to: local)
        await library.checkLocalIntegrity()
        XCTAssertTrue(library.unavailableChunkIDs.contains(chunk.id))
        library.refreshLocalAvailability()
        XCTAssertTrue(library.unavailableChunkIDs.contains(chunk.id))
        XCTAssertTrue(PhoneRecordingLibrary(rootDirectory: appRoot).unavailableChunkIDs.contains(chunk.id))
        try FileManager.default.removeItem(at: local)
        try FileManager.default.copyItem(at: source.url, to: local)
        await library.checkLocalIntegrity()
        XCTAssertTrue(library.unavailableChunkIDs.isEmpty)
        XCTAssertTrue(PhoneRecordingLibrary(rootDirectory: appRoot).unavailableChunkIDs.isEmpty)
        XCTAssertEqual(try FileChecksum.sha256(of: local), chunk.sha256)
    }

    @MainActor
    func testCancelledIntegrityCheckDoesNotMarkHealthyAudioAsCorrupt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        _ = await library.validateAndImport(stagedURL: source.url, source: source.chunk)
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            await library.checkLocalIntegrity()
        }
        task.cancel()
        await task.value
        XCTAssertFalse(library.isCheckingIntegrity)
        XCTAssertTrue(library.unavailableChunkIDs.isEmpty)
        XCTAssertEqual(library.chunks.count, 1)
    }

    @MainActor
    func testInvalidNumericIndexIsPreservedInsteadOfReachingPresentation() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = PhoneRecordingChunk(id: UUID(), sessionID: UUID(), sequence: Int.max,
            filename: "bad.m4a", startedAt: Date(), duration: Double.greatestFiniteMagnitude,
            byteCount: 1, sha256: String(repeating: "a", count: 64), receivedAt: Date())
        let index = root.appendingPathComponent("Support/WatchDayRecorder/phone-library.json")
        try AtomicJSONFile<[PhoneRecordingChunk]>(url: index).save([invalid])
        let original = try Data(contentsOf: index)
        let library = PhoneRecordingLibrary(rootDirectory: root)
        XCTAssertNotNil(library.lastError)
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), original)
        await library.checkLocalIntegrity()
        XCTAssertTrue(library.integrityMessage?.contains("索引无法读取") == true)
    }

    @MainActor
    func testResizedLocalAudioBecomesUnavailableWithoutDroppingItsIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let imported = await library.validateAndImport(stagedURL: source.url, source: source.chunk)
        XCTAssertEqual(imported, .accepted)
        let stored = try XCTUnwrap(library.chunks.first)
        try Data().write(to: library.fileURL(for: stored))
        library.refreshLocalAvailability()
        XCTAssertTrue(library.unavailableChunkIDs.contains(stored.id))
        XCTAssertEqual(library.chunks.count, 1)
        XCTAssertNotNil(library.lastError)
    }

    @MainActor
    func testDifferentChunkCannotOccupyExistingSessionSequence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let second = try makeSource(root: root, id: UUID(), amplitude: 0.3)
        let conflicting = RecordingChunk(id: second.chunk.id, sessionID: first.chunk.sessionID,
            sequence: first.chunk.sequence, filename: second.chunk.filename,
            startedAt: second.chunk.startedAt, duration: second.chunk.duration,
            byteCount: second.chunk.byteCount, sha256: second.chunk.sha256)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let firstResult = await library.validateAndImport(stagedURL: first.url, source: first.chunk)
        XCTAssertEqual(firstResult, .accepted)
        let secondResult = await library.validateAndImport(stagedURL: second.url, source: conflicting)
        guard case .rejected = secondResult else { return XCTFail("A sequence collision must not be positively acknowledged") }
        XCTAssertEqual(library.chunks.map(\.id), [first.chunk.id])
    }

    @MainActor
    func testLegacyIndexedUndecodableDuplicateCannotBeAcknowledged() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let appRoot = root.appendingPathComponent("App")
        let audioDirectory = appRoot.appendingPathComponent("Documents/全天录音")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let url = audioDirectory.appendingPathComponent("legacy.m4a")
        try Data(repeating: 0x7f, count: 4096).write(to: url)
        let source = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0,
            filename: url.lastPathComponent, startedAt: Date(), duration: 1,
            byteCount: 4096, sha256: try FileChecksum.sha256(of: url))
        let legacy = PhoneRecordingChunk(id: source.id, sessionID: source.sessionID,
            sequence: 0, filename: source.filename, startedAt: source.startedAt,
            duration: 1, byteCount: source.byteCount, sha256: source.sha256, receivedAt: Date())
        try AtomicJSONFile<[PhoneRecordingChunk]>(url:
            appRoot.appendingPathComponent("Support/WatchDayRecorder/phone-library.json")
        ).save([legacy])
        let library = PhoneRecordingLibrary(rootDirectory: appRoot)
        let result = await library.validateAndImport(stagedURL: url, source: source)
        guard case .rejected = result else { return XCTFail("A legacy index and matching hash cannot replace a full decode") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(library.chunks.count, 1)
    }

    @MainActor
    func testDistinctIDsWithSamePrefixCannotOverwriteEachOther() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-1111-1111-1111-111111111111"))
        let secondID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-2222-2222-2222-222222222222"))
        let first = try makeSource(root: root, id: firstID, amplitude: 0.1)
        let second = try makeSource(root: root, id: secondID, amplitude: 0.3)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let firstResult = await library.validateAndImport(stagedURL: first.url, source: first.chunk)
        let secondResult = await library.validateAndImport(stagedURL: second.url, source: second.chunk)
        XCTAssertEqual(firstResult, .accepted)
        XCTAssertEqual(secondResult, .accepted)
        XCTAssertEqual(library.chunks.count, 2)
        XCTAssertEqual(Set(library.chunks.map(\.filename)).count, 2)
        for chunk in library.chunks {
            XCTAssertEqual(try FileChecksum.sha256(of: library.fileURL(for: chunk)), chunk.sha256)
        }
    }

    @MainActor
    func testExpiredImportKeepsSourceAndDoesNotCommitLibrary() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let result = await library.validateAndImport(stagedURL: source.url, source: source.chunk, shouldContinue: { false })
        guard case .deferred = result else { return XCTFail("Expiration must defer rather than reject or ACK") }
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
    }

    @MainActor
    func testExpirationDuringAssetValidationDoesNotCommitOrConsumeSource() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        var checks = 0
        let result = await library.validateAndImport(stagedURL: source.url, source: source.chunk, shouldContinue: {
            checks += 1
            return checks == 1
        })
        guard case .deferred = result else { return XCTFail("An expired import must remain pending") }
        XCTAssertGreaterThan(checks, 1)
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
    }

    @MainActor
    func testConflictingChunkIdentityDoesNotReplaceExistingAudio() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(root: root, id: UUID(), amplitude: 0.1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let firstResult = await library.validateAndImport(stagedURL: source.url, source: source.chunk)
        XCTAssertEqual(firstResult, .accepted)
        let conflict = RecordingChunk(
            id: source.chunk.id, sessionID: UUID(), sequence: 0, filename: source.chunk.filename,
            startedAt: source.chunk.startedAt, duration: source.chunk.duration,
            byteCount: source.chunk.byteCount, sha256: source.chunk.sha256
        )
        let result = await library.validateAndImport(stagedURL: source.url, source: conflict)
        guard case .rejected = result else { return XCTFail("Conflicting identity must be rejected") }
        XCTAssertEqual(library.chunks.first?.sessionID, source.chunk.sessionID)
        XCTAssertEqual(try FileChecksum.sha256(of: library.fileURL(for: XCTUnwrap(library.chunks.first))), source.chunk.sha256)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSource(root: URL, id: UUID, amplitude: Float) throws -> (url: URL, chunk: RecordingChunk) {
        let url = root.appendingPathComponent("\(id).m4a")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<16_000 { samples[index] = amplitude * Float(sin(Double(index) * 0.1)) }
            try file.write(from: buffer)
        }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        return (url, RecordingChunk(
            id: id, sessionID: UUID(), sequence: 0, filename: url.lastPathComponent,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 1,
            byteCount: size.int64Value, sha256: try FileChecksum.sha256(of: url)
        ))
    }
}
