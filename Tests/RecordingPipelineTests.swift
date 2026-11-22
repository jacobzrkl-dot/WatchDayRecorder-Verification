import AVFoundation
import XCTest
@testable import WatchDayRecorder

final class RecordingPipelineTests: XCTestCase {
    @MainActor
    func testClosedSessionSurvivesTransferDuplicatesRelaunchAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let watchRoot = root.appendingPathComponent("Watch")
        let phoneRoot = root.appendingPathComponent("Phone")
        let queue = ChunkQueueStore(rootDirectory: watchRoot)
        let watchLedger = RecordingSessionLedger(rootDirectory: watchRoot)
        let phoneLedger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("PhoneLedger"))
        let inbox = PhoneIncomingStore(rootDirectory: root.appendingPathComponent("Inbox"))
        let library = PhoneRecordingLibrary(rootDirectory: phoneRoot)
        let sessionID = UUID()
        try watchLedger.begin(id: sessionID, at: Date())
        var chunks: [RecordingChunk] = []
        for sequence in 0..<2 {
            let id = UUID()
            let partial = queue.partialURL(sessionID: sessionID, sequence: sequence, chunkID: id)
            try AudioTestFixture.writeAAC(to: partial)
            let chunk = try queue.finalize(partialURL: partial, chunkID: id, sessionID: sessionID,
                sequence: sequence, startedAt: Date(), duration: 1)
            try watchLedger.register(chunk)
            chunks.append(chunk)
        }
        try watchLedger.end(id: sessionID, needsRecovery: false)
        let payload = try TransferProtocol.manifestPayload(XCTUnwrap(watchLedger.manifests.first))
        try phoneLedger.merge(XCTUnwrap(TransferProtocol.parseManifest(payload)))
        XCTAssertEqual(phoneLedger.manifests.first?.receiptStatus(for: []), .awaitingChunks(received: 0, expected: 2))

        // Framework transport is deliberately simulated; storage/protocol/audio
        // validation/ACK deletion/export below use production implementations.
        for source in chunks.reversed() {
            let received = try XCTUnwrap(TransferProtocol.chunk(from: TransferProtocol.metadata(for: source)))
            let first = try inbox.stage(fileURL: queue.fileURL(for: source), chunk: received)
            let duplicate = try inbox.stage(fileURL: queue.fileURL(for: source), chunk: received)
            for delivery in [first, duplicate] {
                let result = await library.validateAndImport(stagedURL: inbox.audioURL(for: delivery), source: received)
                guard result == .accepted else { return XCTFail("Import must succeed before ACK: \(result)") }
                let ack = try XCTUnwrap(TransferProtocol.parseAcknowledgement(
                    TransferProtocol.acknowledgement(chunkID: received.id, sha256: received.sha256, accepted: true, reason: nil)
                ))
                try queue.removeAfterAcknowledgement(id: ack.chunkID, sha256: ack.sha256)
                try inbox.remove(delivery)
            }
        }
        XCTAssertTrue(queue.chunks.isEmpty)
        XCTAssertTrue(inbox.pending().isEmpty)
        let reloaded = PhoneRecordingLibrary(rootDirectory: phoneRoot)
        XCTAssertEqual(reloaded.chunks.count, 2)
        XCTAssertEqual(phoneLedger.manifests.first?.receiptStatus(for: reloaded.chunks), .complete)
        for chunk in reloaded.chunks {
            let duration = try await AudioFileValidator.decodedDuration(of: reloaded.fileURL(for: chunk))
            XCTAssertEqual(duration, 1, accuracy: 0.15)
        }
        let exporter = PhoneSessionExporter()
        await exporter.prepare(chunks: reloaded.chunks, directory: reloaded.recordingsDirectory)
        let output = try XCTUnwrap(exporter.exportedURL, exporter.errorMessage ?? "No export")
        defer { try? FileManager.default.removeItem(at: output) }
        let duration = try await AudioFileValidator.decodedDuration(of: output)
        XCTAssertEqual(duration, 2, accuracy: 0.3)
        XCTAssertEqual(ChunkQueueStore(rootDirectory: watchRoot).chunks.count, 0)
    }

    @MainActor
    func testUndecodableAudioWithMatchingSizeAndHashCannotBeAcknowledged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = ChunkQueueStore(rootDirectory: root.appendingPathComponent("Watch"))
        let id = UUID(), sessionID = UUID()
        let partial = queue.partialURL(sessionID: sessionID, sequence: 0, chunkID: id)
        try Data(repeating: 0x7f, count: 4096).write(to: partial)
        let chunk = try queue.finalize(partialURL: partial, chunkID: id, sessionID: sessionID,
            sequence: 0, startedAt: Date(), duration: 1)
        let library = PhoneRecordingLibrary(rootDirectory: root.appendingPathComponent("Phone"))
        let result = await library.validateAndImport(stagedURL: queue.fileURL(for: chunk), source: chunk)
        guard case .rejected = result else { return XCTFail("Matching hash alone must never produce a positive ACK") }
        XCTAssertTrue(library.chunks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.fileURL(for: chunk).path))
    }
}

enum AudioTestFixture {
    static func writeAAC(to url: URL, frames: AVAudioFrameCount = 16_000) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { samples[index] = 0.2 * Float(sin(Double(index) * 0.1)) }
        try file.write(from: buffer)
    }
}
