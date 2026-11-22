import Foundation
import XCTest
@testable import WatchDayRecorder

final class PlaybackAndTimelineTests: XCTestCase {
    @MainActor
    func testProgressSurvivesReopenButDoesNotApplyToChangedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), hash = String(repeating: "a", count: 64)
        PlaybackPositionStore(rootDirectory: root).remember(id: id, sha256: hash, seconds: 120, duration: 600)
        let reopened = PlaybackPositionStore(rootDirectory: root)
        XCTAssertEqual(reopened.position(for: id, sha256: hash, duration: 600), 120)
        XCTAssertEqual(reopened.position(for: id, sha256: String(repeating: "b", count: 64), duration: 600), 0)
        XCTAssertEqual(reopened.position(for: id, sha256: hash, duration: 60), 0)
    }

    @MainActor
    func testFinishedAudioClearsResumeAndInvalidTimesAreIgnored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackPositionStore(rootDirectory: root), id = UUID(), hash = String(repeating: "a", count: 64)
        store.remember(id: id, sha256: hash, seconds: 100, duration: 600)
        store.remember(id: id, sha256: hash, seconds: .nan, duration: 600)
        XCTAssertEqual(store.position(for: id, sha256: hash, duration: 600), 100)
        store.remember(id: id, sha256: hash, seconds: 599, duration: 600)
        XCTAssertEqual(PlaybackPositionStore(rootDirectory: root).position(for: id, sha256: hash, duration: 600), 0)
    }

    func testTimelineSeparatesMissingSegmentsFromMeasuredTimeGap() {
        let id = UUID()
        let chunks = [chunk(0, id, 1000), chunk(1, id, 1010), chunk(3, id, 1050)]
        let gaps = RecordingTimeline.gaps(in: chunks)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.duration, 30)
        XCTAssertEqual(gaps.first?.missingSegments, 1)
    }

    func testClockBackwardsAndMixedSessionsAreNotInventedAsPositiveGaps() {
        let id = UUID()
        XCTAssertTrue(RecordingTimeline.gaps(in: [chunk(0, id, 1000), chunk(1, id, 990)]).isEmpty)
        XCTAssertTrue(RecordingTimeline.gaps(in: [chunk(0, id, 1000), chunk(1, UUID(), 2000)]).isEmpty)
    }

    private func chunk(_ sequence: Int, _ id: UUID, _ time: TimeInterval) -> PhoneRecordingChunk {
        PhoneRecordingChunk(id: UUID(), sessionID: id, sequence: sequence, filename: "\(sequence).m4a",
            startedAt: Date(timeIntervalSince1970: time), duration: 10, byteCount: 1000,
            sha256: String(repeating: "a", count: 64), receivedAt: Date())
    }
}
