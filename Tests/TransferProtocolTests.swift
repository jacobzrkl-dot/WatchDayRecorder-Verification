import XCTest
@testable import WatchDayRecorder

final class TransferProtocolTests: XCTestCase {
    func testBooleanAndFractionalIntegerFieldsAreNotCoercedIntoValidMetadata() {
        let chunk = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0,
            filename: "chunk.m4a", startedAt: Date(), duration: 600,
            byteCount: 2048, sha256: String(repeating: "a", count: 64))
        let invalidValues: [(String, Any)] = [
            (TransferProtocol.Key.schemaVersion, true),
            (TransferProtocol.Key.sequence, 1.5),
            (TransferProtocol.Key.byteCount, 2048.5),
            (TransferProtocol.Key.duration, true)
        ]
        for (key, value) in invalidValues {
            var metadata = TransferProtocol.metadata(for: chunk)
            metadata[key] = value
            XCTAssertNil(TransferProtocol.chunk(from: metadata))
        }
    }

    func testValuesThatOverflowPresentationAreRejectedAtProtocolBoundary() {
        let chunk = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0,
            filename: "chunk.m4a", startedAt: Date(), duration: 600,
            byteCount: 2048, sha256: String(repeating: "a", count: 64))
        let valid = TransferProtocol.metadata(for: chunk)
        for invalid in [Int.max, Int(Int32.max)] {
            var metadata = valid
            metadata[TransferProtocol.Key.sequence] = invalid
            XCTAssertNil(TransferProtocol.chunk(from: metadata))
        }
        var metadata = valid
        metadata[TransferProtocol.Key.duration] = Double.greatestFiniteMagnitude
        XCTAssertNil(TransferProtocol.chunk(from: metadata))
        metadata = valid
        metadata[TransferProtocol.Key.startedAt] = Double.greatestFiniteMagnitude
        XCTAssertNil(TransferProtocol.chunk(from: metadata))
    }

    func testNonHexadecimalChecksumIsRejected() {
        let chunk = RecordingChunk(id: UUID(), sessionID: UUID(), sequence: 0,
            filename: "chunk.m4a", startedAt: Date(), duration: 600,
            byteCount: 2048, sha256: String(repeating: "z", count: 64))
        XCTAssertNil(TransferProtocol.chunk(from: TransferProtocol.metadata(for: chunk)))
    }

    func testRetryRequestIsDistinctFromFileAcknowledgement() {
        let request = TransferProtocol.retryRequest()
        XCTAssertTrue(TransferProtocol.isRetryRequest(request))
        XCTAssertNil(TransferProtocol.parseAcknowledgement(request))
        var invalid = request
        invalid[TransferProtocol.Key.schemaVersion] = 999
        XCTAssertFalse(TransferProtocol.isRetryRequest(invalid))
    }
    func testNonFiniteDurationIsRejected() {
        let chunk = RecordingChunk(
            id: UUID(), sessionID: UUID(), sequence: 0, filename: "chunk.m4a",
            startedAt: Date(), duration: 600, byteCount: 2_048,
            sha256: String(repeating: "a", count: 64)
        )
        var metadata = TransferProtocol.metadata(for: chunk)
        metadata[TransferProtocol.Key.duration] = Double.infinity
        XCTAssertNil(TransferProtocol.chunk(from: metadata))
        metadata[TransferProtocol.Key.duration] = Double.nan
        XCTAssertNil(TransferProtocol.chunk(from: metadata))
    }

    func testChunkMetadataRoundTrip() throws {
        let chunk = RecordingChunk(
            id: UUID(),
            sessionID: UUID(),
            sequence: 7,
            filename: "chunk.m4a",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 600,
            byteCount: 2_400_000,
            sha256: String(repeating: "a", count: 64)
        )

        let decoded = try XCTUnwrap(TransferProtocol.chunk(from: TransferProtocol.metadata(for: chunk)))
        XCTAssertEqual(decoded.id, chunk.id)
        XCTAssertEqual(decoded.sessionID, chunk.sessionID)
        XCTAssertEqual(decoded.sequence, chunk.sequence)
        XCTAssertEqual(decoded.filename, chunk.filename)
        XCTAssertEqual(decoded.duration, chunk.duration)
        XCTAssertEqual(decoded.byteCount, chunk.byteCount)
        XCTAssertEqual(decoded.sha256, chunk.sha256)
    }

    func testAcknowledgementRoundTrip() throws {
        let id = UUID()
        let hash = String(repeating: "b", count: 64)
        let payload = TransferProtocol.acknowledgement(
            chunkID: id,
            sha256: hash,
            accepted: false,
            reason: "bad file"
        )

        let decoded = try XCTUnwrap(TransferProtocol.parseAcknowledgement(payload))
        XCTAssertEqual(decoded.chunkID, id)
        XCTAssertEqual(decoded.sha256, hash)
        XCTAssertFalse(decoded.accepted)
        XCTAssertEqual(decoded.reason, "bad file")
    }

    func testQuickRecordRoute() {
        XCTAssertTrue(AppRoute.isQuickRecord(AppRoute.quickRecordURL))
        XCTAssertFalse(AppRoute.isQuickRecord(URL(string: "watchdayrecorder://status")!))
        XCTAssertFalse(AppRoute.isQuickRecord(URL(string: "https://example.com/record")!))
    }
}
