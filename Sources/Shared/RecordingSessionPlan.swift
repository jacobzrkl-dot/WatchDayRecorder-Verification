import Foundation

enum RecordingSessionPlan {
    static func selectedChunks(_ chunks: [PhoneRecordingChunk], ids: Set<UUID>, unavailable: Set<UUID>) -> [PhoneRecordingChunk] {
        chunks.filter { ids.contains($0.id) && !unavailable.contains($0.id) }
    }
    static func matchesPlaylist(sessionID: UUID?, orderedIDs: [UUID], chunks: [PhoneRecordingChunk]) -> Bool {
        guard let ordered = try? orderedChunks(chunks, allowGaps: true) else { return false }
        return sessionID == ordered.first?.sessionID && orderedIDs == ordered.map(\.id)
    }
    static func orderedChunks(_ chunks: [PhoneRecordingChunk], allowGaps: Bool = false) throws -> [PhoneRecordingChunk] {
        guard let first = chunks.first else { throw SessionPlanError.empty }
        guard chunks.allSatisfy({ $0.sessionID == first.sessionID }) else {
            throw SessionPlanError.mixedSessions
        }
        guard chunks.allSatisfy(RecordingMetadataValidation.valid),
              Set(chunks.map(\.id)).count == chunks.count,
              Set(chunks.map(\.sequence)).count == chunks.count,
              allowGaps || ChunkSequenceValidator.isContinuous(chunks.map(\.sequence)) else {
            throw SessionPlanError.missingChunks
        }
        return chunks.sorted { $0.sequence < $1.sequence }
    }
}

enum SessionPlanError: LocalizedError {
    case empty
    case mixedSessions
    case missingChunks

    var errorDescription: String? {
        switch self {
        case .empty: "还没有收到录音分段"
        case .mixedSessions: "不能将不同场次的录音合并"
        case .missingChunks: "已收到的分段有缺失或重复，请先完成同步；仍可逐段播放和导出"
        }
    }
}
