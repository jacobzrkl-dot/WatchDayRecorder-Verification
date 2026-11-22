import Foundation

struct RecordingRecoveryName: Equatable, Sendable {
    let sessionID: UUID
    let sequence: Int
    let chunkID: UUID

    init?(url: URL) {
        let name = url.lastPathComponent
        let stem: String
        if name.hasSuffix(".partial.m4a") {
            stem = String(name.dropLast(".partial.m4a".count))
        } else if name.hasSuffix(".m4a") {
            stem = String(name.dropLast(".m4a".count))
        } else { return nil }
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, let sessionID = UUID(uuidString: String(parts[0])),
              let sequence = Int(parts[1]), RecordingMetadataValidation.sequence(sequence),
              let chunkID = UUID(uuidString: String(parts[2])) else { return nil }
        self.sessionID = sessionID
        self.sequence = sequence
        self.chunkID = chunkID
    }
}
