import XCTest
@testable import WatchDayRecorder

final class RecordingSessionPlanTests: XCTestCase {
    func testSelectionAndFullSessionHaveDifferentPlaybackIdentity() {
        let id = UUID(), first = chunk(0, UUID())
        let selected = [chunk(1, id), chunk(2, id)]
        XCTAssertTrue(RecordingSessionPlan.matchesPlaylist(sessionID: id, orderedIDs: selected.map(\.id), chunks: Array(selected.reversed())))
        XCTAssertFalse(RecordingSessionPlan.matchesPlaylist(sessionID: id, orderedIDs: selected.map(\.id), chunks: [chunk(0, id)] + selected))
        XCTAssertFalse(RecordingSessionPlan.matchesPlaylist(sessionID: id, orderedIDs: selected.map(\.id), chunks: [first] + selected))
    }

    func testAvailabilityChangesEffectiveSelectionWithoutChangingMetadataOrIDs() {
        let id = UUID(), chunks = [chunk(0, UUID()), chunk(1, UUID())]
        let ids = Set(chunks.map(\.id))
        let before = RecordingSessionPlan.selectedChunks(chunks, ids: ids, unavailable: [])
        let after = RecordingSessionPlan.selectedChunks(chunks, ids: ids, unavailable: [chunks[0].id])
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.map(\.id), [chunks[1].id])
        XCTAssertEqual(RecordingSessionPlan.selectedChunks(chunks, ids: [id], unavailable: []), [])
    }

    func testExplicitSelectionAllowsGapsButRejectsDuplicateOrMixedIdentity() throws {
        let id = UUID()
        let first = chunk(2, id), second = chunk(5, id)
        XCTAssertEqual(try RecordingSessionPlan.orderedChunks([second, first], allowGaps: true).map(\.sequence), [2, 5])
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([first, second]))
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([first, first], allowGaps: true))
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([first, chunk(6, UUID())], allowGaps: true))
    }

    func testPlaybackAndExportUseSequenceOrder() throws {
        let id = UUID()
        let result = try RecordingSessionPlan.orderedChunks([chunk(1, id), chunk(0, id)])
        XCTAssertEqual(result.map(\.sequence), [0, 1])
    }

    func testMissingChunkPreventsSilentSessionAssembly() {
        let id = UUID()
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([chunk(1, id)]))
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([chunk(0, id), chunk(2, id)]))
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([chunk(0, id), chunk(0, id)]))
    }

    func testDifferentSessionsAndEmptyInputAreRejected() {
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([]))
        XCTAssertThrowsError(try RecordingSessionPlan.orderedChunks([chunk(0, UUID()), chunk(1, UUID())]))
    }

    private func chunk(_ sequence: Int, _ sessionID: UUID) -> PhoneRecordingChunk {
        PhoneRecordingChunk(
            id: UUID(), sessionID: sessionID, sequence: sequence,
            filename: "\(sequence).m4a", startedAt: Date(), duration: 600,
            byteCount: 2_048, sha256: String(repeating: "a", count: 64), receivedAt: Date()
        )
    }
}
