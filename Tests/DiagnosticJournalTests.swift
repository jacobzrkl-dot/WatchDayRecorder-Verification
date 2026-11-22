import Foundation
import XCTest
@testable import WatchDayRecorder

final class DiagnosticJournalTests: XCTestCase {
    func testBoundedJournalSurvivesReopenInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(rootDirectory: root, limit: 2)
        for index in 0..<3 { XCTAssertTrue(journal.record("test", "event_\(index)")) }
        XCTAssertEqual(DiagnosticJournal(rootDirectory: root, limit: 2).snapshot().map(\.code), ["event_1", "event_2"])
    }

    func testFailedLogWriteRemainsNonThrowingAndKeepsMemoryEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(rootDirectory: root)
        XCTAssertFalse(journal.record("test", "disk_unavailable"))
        XCTAssertEqual(journal.snapshot().first?.code, "disk_unavailable")
    }
}
