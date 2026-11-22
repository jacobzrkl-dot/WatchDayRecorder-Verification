import Foundation
import XCTest
@testable import WatchDayRecorder

final class CompanionEvidenceTests: XCTestCase {
    func testOlderSubsecondStatusCannotReplaceNewerStopAfterRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stopped = WatchCaptureStatus(timestamp: now, mode: .stopped, pendingChunks: 1, battery: 0.5, error: nil)
        let old = WatchCaptureStatus(timestamp: now.addingTimeInterval(-0.01), mode: .recording, pendingChunks: 1, battery: 0.5, error: nil)
        XCTAssertTrue(try CompanionEvidenceStore(rootDirectory: root).save(stopped))
        let reopened = CompanionEvidenceStore(rootDirectory: root)
        XCTAssertFalse(try reopened.save(old))
        XCTAssertEqual(reopened.status()?.mode, .stopped)
    }

    func testStaleOrDuplicateReportsNeverTriggerStopAlerts() {
        let now = Date()
        let stale = WatchCaptureStatus(timestamp: now.addingTimeInterval(-300), mode: .paused, pendingChunks: 0, battery: 1, error: nil)
        XCTAssertTrue(stale.summary(at: now).contains("无法确认"))
        XCTAssertFalse(stale.shouldNotify(after: nil, now: now))
        let fresh = WatchCaptureStatus(timestamp: now, mode: .paused, pendingChunks: 0, battery: 1, error: nil)
        XCTAssertTrue(fresh.shouldNotify(after: nil, now: now))
        XCTAssertTrue(fresh.shouldNotify(after: stale, now: now))
        XCTAssertFalse(fresh.shouldNotify(after: fresh, now: now))
    }

    func testStatusProtocolRejectsIncompatibleVersion() throws {
        let status = WatchCaptureStatus(timestamp: Date(), mode: .recording, pendingChunks: 2, battery: 0.8, error: nil)
        var wire = try TransferProtocol.statusPayload(status)
        XCTAssertEqual(TransferProtocol.parseStatus(wire), status)
        wire[TransferProtocol.Key.schemaVersion] = 999
        XCTAssertNil(TransferProtocol.parseStatus(wire))
        XCTAssertTrue(TransferProtocol.hasUnsupportedVersion(wire))
    }

    func testWatchReportSurvivesStorageAndIsIncludedInPhoneExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(rootDirectory: root.appendingPathComponent("Watch"))
        journal.record("recorder", "test_error")
        let report = try journal.export(context: ["scope": "Watch"])
        defer { try? FileManager.default.removeItem(at: report) }
        let evidence = CompanionEvidenceStore(rootDirectory: root.appendingPathComponent("Phone"))
        try evidence.acceptDiagnostics(Data(contentsOf: report))
        let reopened = CompanionEvidenceStore(rootDirectory: root.appendingPathComponent("Phone"))
        let combined = try DiagnosticJournal(rootDirectory: root.appendingPathComponent("Local")).export(context: [:], watch: reopened.diagnostics())
        defer { try? FileManager.default.removeItem(at: combined) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticReport.self, from: Data(contentsOf: combined))
        XCTAssertEqual(decoded.watch?.events.first?.code, "test_error")
        XCTAssertTrue(decoded.events.isEmpty)
        XCTAssertEqual(decoded.watch?.context["scope"], "Watch")
    }

    func testMalformedDiagnosticsCannotReplaceSavedEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = CompanionEvidenceStore(rootDirectory: root)
        XCTAssertThrowsError(try evidence.acceptDiagnostics(Data(repeating: 1, count: 2 * 1024 * 1024 + 1)))
        XCTAssertNil(evidence.diagnostics())
    }
}
