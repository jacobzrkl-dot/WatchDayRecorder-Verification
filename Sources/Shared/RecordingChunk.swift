import Foundation

enum ChunkTransferState: String, Codable, Sendable {
    case ready
    case queued
    case awaitingAcknowledgement
    case failed
}

struct RecordingChunk: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let filename: String
    let startedAt: Date
    let duration: TimeInterval
    let byteCount: Int64
    let sha256: String
    var state: ChunkTransferState
    var attemptCount: Int
    var lastAttemptAt: Date?
    var lastError: String?

    init(
        id: UUID,
        sessionID: UUID,
        sequence: Int,
        filename: String,
        startedAt: Date,
        duration: TimeInterval,
        byteCount: Int64,
        sha256: String,
        state: ChunkTransferState = .ready,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.filename = filename
        self.startedAt = startedAt
        self.duration = duration
        self.byteCount = byteCount
        self.sha256 = sha256
        self.state = state
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }
}

struct PhoneRecordingChunk: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let filename: String
    let startedAt: Date
    let duration: TimeInterval
    let byteCount: Int64
    let sha256: String
    let receivedAt: Date
}
