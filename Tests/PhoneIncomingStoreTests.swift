import Foundation
import XCTest
@testable import WatchDayRecorder

final class PhoneIncomingStoreTests: XCTestCase {
    func testMissingAudioIntentCleansMetadataOnNextScan() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 3, count: 2048).write(to: source)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = try inbox.stage(fileURL: source, chunk: sampleChunk())
        try FileManager.default.removeItem(at: inbox.audioURL(for: delivery))
        let metadata = inbox.rootDirectory.appendingPathComponent("\(delivery.id).json")
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.appendingPathExtension("backup").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMalformedDeliveryCannotReadOrRemoveAudioOutsideInbox() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.m4a")
        try Data(repeating: 3, count: 2048).write(to: outside)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = PhoneIncomingDelivery(id: UUID(), chunk: sampleChunk(),
            audioFilename: "../outside.m4a", receivedAt: Date())
        let metadata = inbox.rootDirectory.appendingPathComponent("\(delivery.id).json")
        try AtomicJSONFile<PhoneIncomingDelivery>(url: metadata).save(delivery)
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertThrowsError(try inbox.remove(delivery))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testDuplicateDeliveriesUseDifferentDurablePaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 3, count: 2_048).write(to: source)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let chunk = sampleChunk()

        let first = try inbox.stage(fileURL: source, chunk: chunk)
        let second = try inbox.stage(fileURL: source, chunk: chunk)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.audioFilename, second.audioFilename)
        XCTAssertEqual(PhoneIncomingStore(rootDirectory: inbox.rootDirectory).pending().count, 2)
    }

    func testCompletedDeliveryIsRemovedFromDisk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 4, count: 2_048).write(to: source)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = try inbox.stage(fileURL: source, chunk: sampleChunk())

        try inbox.remove(delivery)

        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(for: delivery).path))
    }

    func testCorruptMetadataPreservesAudioForRecovery() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 5, count: 2_048).write(to: source)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = try inbox.stage(fileURL: source, chunk: sampleChunk())
        let metadataURL = inbox.rootDirectory
            .appendingPathComponent("\(delivery.id.uuidString).json")

        try Data("broken".utf8).write(to: metadataURL, options: .atomic)
        try Data("broken".utf8).write(
            to: metadataURL.appendingPathExtension("backup"),
            options: .atomic
        )

        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.audioURL(for: delivery).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testMissingPrimaryMetadataRecoversFromBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 5, count: 2_048).write(to: source)
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = try inbox.stage(fileURL: source, chunk: sampleChunk())
        try FileManager.default.removeItem(at: inbox.rootDirectory.appendingPathComponent("\(delivery.id.uuidString).json"))

        XCTAssertEqual(inbox.pending().map(\.id), [delivery.id])
    }

    private func sampleChunk() -> RecordingChunk {
        RecordingChunk(
            id: UUID(),
            sessionID: UUID(),
            sequence: 0,
            filename: "watch.m4a",
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 10,
            byteCount: 2_048,
            sha256: String(repeating: "b", count: 64)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchDayRecorderInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
