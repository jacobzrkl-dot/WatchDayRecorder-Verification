import AVFoundation
import XCTest
@testable import WatchDayRecorder

final class PhoneSessionExporterTests: XCTestCase {
    @MainActor
    func testSelectedGappedSegmentsExportOnlySelectedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let chunks = try [makeChunk(sequence: 2, sessionID: id, root: root), makeChunk(sequence: 5, sessionID: id, root: root)]
        let exporter = PhoneSessionExporter()
        await exporter.prepare(chunks: chunks, directory: root, displayName: String(repeating: "👨‍👩‍👧‍👦", count: 80), allowGaps: true)
        let output = try XCTUnwrap(exporter.exportedURL, exporter.errorMessage ?? "No export")
        defer { try? FileManager.default.removeItem(at: output) }
        let duration = try await AudioFileValidator.decodedDuration(of: output)
        XCTAssertEqual(duration, 2, accuracy: 0.3)
        XCTAssertTrue(exporter.statusText.contains("所选"))
        XCTAssertTrue(output.lastPathComponent.hasPrefix("录音_所选片段_"))
        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        for chunk in chunks { XCTAssertEqual(try FileChecksum.sha256(of: root.appendingPathComponent(chunk.filename)), chunk.sha256) }
    }

    @MainActor
    func testInsufficientSpaceFailsBeforeCreatingExportAndPreservesAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = try makeChunk(sequence: 0, sessionID: UUID(), root: root)
        let exporter = PhoneSessionExporter(availableBytes: { 0 })
        await exporter.prepare(chunks: [chunk], directory: root)
        XCTAssertNil(exporter.exportedURL)
        XCTAssertTrue(exporter.errorMessage?.contains("预留") == true)
        XCTAssertEqual(try FileChecksum.sha256(of: root.appendingPathComponent(chunk.filename)), chunk.sha256)
    }

    @MainActor
    func testExportCombinesReceivedChunksAndPreservesSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let chunks = try [makeChunk(sequence: 0, sessionID: sessionID, root: root),
                          makeChunk(sequence: 1, sessionID: sessionID, root: root)]
        let exporter = PhoneSessionExporter()
        await exporter.prepare(chunks: Array(chunks.reversed()), directory: root, displayName: "../客户/会议")
        let output = try XCTUnwrap(exporter.exportedURL, exporter.errorMessage ?? "No export")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(output.deletingLastPathComponent().lastPathComponent, "SessionExports")
        XCTAssertTrue(output.lastPathComponent.contains("客户_会议"))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.3)
        for chunk in chunks {
            XCTAssertEqual(try FileChecksum.sha256(of: root.appendingPathComponent(chunk.filename)), chunk.sha256)
        }
    }

    @MainActor
    func testMissingSourceReportsFailureWithoutOfferingExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = try makeChunk(sequence: 0, sessionID: UUID(), root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(chunk.filename))
        let exporter = PhoneSessionExporter()
        await exporter.prepare(chunks: [chunk], directory: root)
        XCTAssertNil(exporter.exportedURL)
        XCTAssertNotNil(exporter.errorMessage)
        XCTAssertFalse(exporter.isPreparing)
    }

    private func makeChunk(sequence: Int, sessionID: UUID, root: URL) throws -> PhoneRecordingChunk {
        let url = root.appendingPathComponent("\(sequence).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<16_000 { samples[index] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return PhoneRecordingChunk(
            id: UUID(), sessionID: sessionID, sequence: sequence, filename: url.lastPathComponent,
            startedAt: Date(), duration: 1, byteCount: size?.int64Value ?? 0,
            sha256: try FileChecksum.sha256(of: url), receivedAt: Date()
        )
    }
}
