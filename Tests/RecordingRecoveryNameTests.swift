import Foundation
import XCTest
@testable import WatchDayRecorder

final class RecordingRecoveryNameTests: XCTestCase {
    func testRecoveryRejectsOverflowingSequenceNames() {
        for sequence in [Int.max, Int(Int32.max)] {
            let name = "\(UUID())_\(sequence)_\(UUID()).partial.m4a"
            XCTAssertNil(RecordingRecoveryName(url: URL(fileURLWithPath: "/\(name)")))
        }
    }

    func testRecoveryRecognizesOnlyOwnedRecordingNames() throws {
        let session = UUID()
        let chunk = UUID()
        let stem = "\(session.uuidString)_3_\(chunk.uuidString)"
        let partial = try XCTUnwrap(RecordingRecoveryName(url: URL(fileURLWithPath: "/\(stem).partial.m4a")))
        let final = try XCTUnwrap(RecordingRecoveryName(url: URL(fileURLWithPath: "/\(stem).m4a")))
        XCTAssertEqual(partial, final)
        XCTAssertEqual(partial.sessionID, session)
        XCTAssertEqual(partial.chunkID, chunk)
        XCTAssertEqual(partial.sequence, 3)
        XCTAssertNil(RecordingRecoveryName(url: URL(fileURLWithPath: "/unknown.m4a")))
        XCTAssertNil(RecordingRecoveryName(url: URL(fileURLWithPath: "/\(session)_-1_\(chunk).m4a")))
    }
}
