import Foundation
import XCTest
@testable import WatchDayRecorder

final class PhoneReceiverFlowTests: XCTestCase {
    @MainActor
    func testAudioOnlyRemovalFailureKeepsIntentAndCanRetryAfterRelaunch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RefusingRemovalFileManager()
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"), fileManager: manager)
        let delivery = try stage(root: root, inbox: inbox)
        manager.blockedPrefix = delivery.id.uuidString
        manager.blockAudioOnly = true
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let ledger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger"))
        let receiver = PhoneConnectivityReceiver(library: library, ledger: ledger, inbox: inbox,
            session: nil, acknowledgementSender: { _, _, _ in true }, leaseFactory: { TestImportLease() })
        await receiver.resumePendingImports()
        XCTAssertEqual(inbox.pending().map(\.id), [delivery.id])
        let reopened = PhoneIncomingStore(rootDirectory: inbox.rootDirectory)
        let retry = PhoneConnectivityReceiver(library: library, ledger: ledger, inbox: reopened,
            session: nil, acknowledgementSender: { _, _, _ in true }, leaseFactory: { TestImportLease() })
        await retry.resumePendingImports()
        XCTAssertTrue(reopened.pending().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.audioURL(for: delivery).path))
        XCTAssertEqual(library.chunks.count, 1)
    }

    @MainActor
    func testMetadataOnlyCleanupFailureRecoversWithoutLeavingStaleWarning() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RefusingRemovalFileManager()
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"), fileManager: manager)
        let delivery = try stage(root: root, inbox: inbox)
        manager.blockedPrefix = delivery.id.uuidString
        manager.blockMetadataOnly = true
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let receiver = PhoneConnectivityReceiver(library: library,
            ledger: RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger")),
            inbox: inbox, session: nil, acknowledgementSender: { _, _, _ in true },
            leaseFactory: { TestImportLease() })
        await receiver.resumePendingImports()
        XCTAssertEqual(library.chunks.count, 1)
        XCTAssertNotNil(receiver.lastError)
        let metadata = inbox.rootDirectory.appendingPathComponent("\(delivery.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
        manager.blockedPrefix = nil
        await receiver.resumePendingImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.appendingPathExtension("backup").path))
        XCTAssertNil(receiver.lastError)
        XCTAssertEqual(receiver.pendingCleanupCount, 0)
        XCTAssertEqual(library.chunks.count, 1)
    }

    @MainActor
    func testUnremovableFirstDeliveryDoesNotBlockFollowingHealthyDelivery() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RefusingRemovalFileManager()
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"), fileManager: manager)
        let first = try stage(root: root, inbox: inbox)
        let second = try stage(root: root, inbox: inbox)
        let later = PhoneIncomingDelivery(id: second.id, chunk: second.chunk, audioFilename: second.audioFilename,
            receivedAt: first.receivedAt.addingTimeInterval(10))
        try AtomicJSONFile<PhoneIncomingDelivery>(url: inbox.rootDirectory.appendingPathComponent("\(second.id).json")).save(later)
        manager.blockedPrefix = first.id.uuidString
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        let ledger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger"))
        var acknowledgements: [UUID] = []
        let receiver = PhoneConnectivityReceiver(library: library, ledger: ledger, inbox: inbox, session: nil,
            acknowledgementSender: { chunk, accepted, _ in
                XCTAssertTrue(accepted)
                acknowledgements.append(chunk.id)
                return true
            }, leaseFactory: { TestImportLease() })
        await receiver.resumePendingImports()
        XCTAssertEqual(Set(library.chunks.map(\.id)), Set([first.chunk.id, second.chunk.id]))
        XCTAssertEqual(Set(acknowledgements), Set([first.chunk.id, second.chunk.id]))
        XCTAssertEqual(inbox.pending().map(\.id), [first.id])
        XCTAssertEqual(receiver.pendingCleanupCount, 1)
        XCTAssertNotNil(receiver.lastError)
        manager.blockedPrefix = nil
        await receiver.resumePendingImports()
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertEqual(library.chunks.count, 2)
        XCTAssertEqual(receiver.pendingCleanupCount, 0)
        XCTAssertNil(receiver.lastError)
    }

    @MainActor
    func testUnavailableAcknowledgementRetainsInboxAndRetriesWithoutDuplicatingLibrary() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let delivery = try stage(root: root, inbox: inbox)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        var canSend = false
        let receiver = PhoneConnectivityReceiver(library: library,
            ledger: RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger")),
            inbox: inbox, session: nil, acknowledgementSender: { _, _, _ in canSend },
            leaseFactory: { TestImportLease() })
        await receiver.resumePendingImports()
        XCTAssertEqual(library.chunks.count, 1)
        XCTAssertEqual(inbox.pending().map(\.id), [delivery.id])
        canSend = true
        await receiver.resumePendingImports()
        XCTAssertTrue(inbox.pending().isEmpty)
        XCTAssertEqual(library.chunks.count, 1)
    }

    @MainActor
    func testExpiredBudgetNeverAcknowledgesUnvalidatedAudioAndCanResume() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        _ = try stage(root: root, inbox: inbox)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("App"))
        var expired = true
        var acknowledgements = 0
        let receiver = PhoneConnectivityReceiver(library: library,
            ledger: RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger")),
            inbox: inbox, session: nil, acknowledgementSender: { _, _, _ in acknowledgements += 1; return true },
            leaseFactory: { TestImportLease(expired: expired) })
        await receiver.resumePendingImports()
        XCTAssertEqual(acknowledgements, 0)
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertEqual(inbox.pending().count, 1)
        expired = false
        await receiver.resumePendingImports()
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stage(root: URL, inbox: PhoneIncomingStore) throws -> PhoneIncomingDelivery {
        let url = root.appendingPathComponent("\(UUID()).m4a")
        try AudioTestFixture.writeAAC(to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        let chunk = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0,
            filename: url.lastPathComponent, startedAt: Date(), duration: 1,
            byteCount: size.int64Value, sha256: try FileChecksum.sha256(of: url))
        return try inbox.stage(fileURL: url, chunk: chunk)
    }
}

@MainActor
private final class TestImportLease: ImportProcessingLease {
    var isExpired: Bool
    var onExpiration: (() -> Void)?
    init(expired: Bool = false) { isExpired = expired }
    func finish() { onExpiration = nil }
}

private final class RefusingRemovalFileManager: FileManager, @unchecked Sendable {
    var blockedPrefix: String?
    var blockMetadataOnly = false
    var blockAudioOnly = false
    override func removeItem(at url: URL) throws {
        if let blockedPrefix, url.lastPathComponent.hasPrefix(blockedPrefix),
           (!blockMetadataOnly || url.pathExtension == "json" || url.pathExtension == "backup"),
           (!blockAudioOnly || url.pathExtension == "m4a") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
