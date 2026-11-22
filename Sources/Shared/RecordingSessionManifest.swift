import Foundation

struct SessionChunkReference: Codable, Equatable, Sendable {
    let id: UUID
    let sequence: Int
    let sha256: String

    init(_ chunk: RecordingChunk) {
        id = chunk.id
        sequence = chunk.sequence
        sha256 = chunk.sha256
    }
}

struct RecordingSessionManifest: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var updatedAt: Date
    var endedAt: Date?
    var revision: Int
    var requiresRecovery: Bool
    var wasInterrupted: Bool
    var chunks: [SessionChunkReference]

    func receiptStatus(for received: [PhoneRecordingChunk]) -> SessionReceiptStatus {
        guard isValid else { return .conflict }
        guard !requiresRecovery else { return .needsRecovery }
        guard endedAt != nil else { return .recording }
        if chunks.isEmpty && received.isEmpty { return .noAudio }
        guard received.allSatisfy({ $0.sessionID == id }),
              Set(received.map(\.id)).count == received.count else { return .conflict }
        let expected = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        guard received.allSatisfy({ chunk in
            guard let reference = expected[chunk.id] else { return false }
            return reference.sequence == chunk.sequence && reference.sha256 == chunk.sha256
        }) else { return .conflict }
        guard received.count == chunks.count else {
            return .awaitingChunks(received: received.count, expected: chunks.count)
        }
        guard ChunkSequenceValidator.isContinuous(chunks.map(\.sequence)) else { return .needsRecovery }
        return .complete
    }

    var isValid: Bool {
        revision > 0 && revision < Int.max && RecordingMetadataValidation.date(startedAt)
            && RecordingMetadataValidation.date(updatedAt)
            && (endedAt.map(RecordingMetadataValidation.date) ?? true)
            && Set(chunks.map(\.id)).count == chunks.count
            && Set(chunks.map(\.sequence)).count == chunks.count
            && chunks.allSatisfy { RecordingMetadataValidation.sequence($0.sequence) }
            && chunks.allSatisfy { RecordingMetadataValidation.checksum($0.sha256) }
    }
}

enum SessionReceiptStatus: Equatable {
    case recording
    case needsRecovery
    case awaitingChunks(received: Int, expected: Int)
    case complete
    case conflict
    case noAudio

    var title: String {
        switch self {
        case .recording: "录音中 / 尚未收到结束确认"
        case .needsRecovery: "手表有中断录音待恢复"
        case let .awaitingChunks(received, expected): "同步中 · 已收 \(received) / 共 \(expected) 段"
        case .complete: "整场已收齐"
        case .conflict: "分段与场次清单不一致，请重试同步"
        case .noAudio: "本场未产生可用音频"
        }
    }
}
