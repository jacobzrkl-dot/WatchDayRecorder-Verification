import Foundation
import XCTest
@testable import WatchDayRecorder

final class PhoneSessionCatalogTests: XCTestCase {
    @MainActor
    func testRenameAndArchiveSurviveRelaunchAndRestore() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let first = PhoneSessionCatalog(rootDirectory: root)
        try first.rename(id, title: "  客户会议  ")
        try first.setArchived(id, true)
        let reopened = PhoneSessionCatalog(rootDirectory: root)
        XCTAssertEqual(reopened.title(for: id), "客户会议")
        XCTAssertTrue(reopened.isArchived(id))
        try reopened.setArchived(id, false)
        XCTAssertEqual(reopened.title(for: id), "客户会议")
        XCTAssertFalse(PhoneSessionCatalog(rootDirectory: root).isArchived(id))
    }

    @MainActor
    func testInvalidTitleDoesNotOverwriteExistingName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = PhoneSessionCatalog(rootDirectory: root)
        let id = UUID()
        try catalog.rename(id, title: "保留这个名称")
        XCTAssertThrowsError(try catalog.rename(id, title: "   "))
        XCTAssertThrowsError(try catalog.rename(id, title: String(repeating: "长", count: 81)))
        XCTAssertEqual(catalog.title(for: id), "保留这个名称")
    }

    @MainActor
    func testCorruptCatalogCannotBeOverwrittenByNewMetadata() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session-catalog.json")
        let original = Data("corrupt metadata".utf8)
        try original.write(to: url)
        let catalog = PhoneSessionCatalog(rootDirectory: root)
        XCTAssertThrowsError(try catalog.setArchived(UUID(), true))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSearchMatchesNameOrLocalDateAndTrimsQuery() {
        let date = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        XCTAssertTrue(RecordingSearch.matches(query: " 客户 ", title: "客户会议", date: date))
        XCTAssertTrue(RecordingSearch.matches(query: formatter.string(from: date), title: nil, date: date))
        XCTAssertTrue(RecordingSearch.matches(query: "  ", title: nil, date: date))
        XCTAssertFalse(RecordingSearch.matches(query: "找不到的录音", title: "客户会议", date: date))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
