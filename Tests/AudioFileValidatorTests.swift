import Foundation
import XCTest
@testable import WatchDayRecorder

final class AudioFileValidatorTests: XCTestCase {
    func testDecodesAllBuffersOfAACFixture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioTestFixture.writeAAC(to: url, frames: 48_000)
        let duration = try await AudioFileValidator.decodedDuration(of: url)
        XCTAssertEqual(duration, 3, accuracy: 0.15)
    }

    func testMalformedFileDoesNotPassDecoder() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 8192).write(to: url)
        do {
            _ = try await AudioFileValidator.decodedDuration(of: url)
            XCTFail("Malformed data must be rejected")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testCancelledParentDoesNotReturnSuccessfulValidation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioTestFixture.writeAAC(to: url)
        let task = Task {
            // Gate execution until cancellation is visible, avoiding a race
            // where a short valid fixture finishes before the test cancels.
            while !Task.isCancelled { await Task.yield() }
            return try await AudioFileValidator.decodedDuration(of: url)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled validation must not succeed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
