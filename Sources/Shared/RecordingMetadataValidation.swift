import Foundation

/// These checks apply to wire messages AND durable indexes: decoding JSON
/// successfully does not make its numbers or filenames safe to use.
enum RecordingMetadataValidation {
    static func sequence(_ value: Int) -> Bool {
        value >= 0 && value < Int(Int32.max)
    }

    static func duration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0 && value <= TimeInterval(Int32.max)
    }

    static func date(_ value: Date) -> Bool {
        value.timeIntervalSince1970.isFinite && value >= .distantPast && value <= .distantFuture
    }

    static func filename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    static func checksum(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func valid(_ chunk: RecordingChunk) -> Bool {
        sequence(chunk.sequence) && duration(chunk.duration) && date(chunk.startedAt)
            && filename(chunk.filename) && checksum(chunk.sha256)
            && chunk.byteCount > 0 && chunk.byteCount <= Int64(Int32.max)
            && chunk.attemptCount >= 0 && (chunk.lastAttemptAt.map(date) ?? true)
    }

    static func valid(_ chunk: PhoneRecordingChunk) -> Bool {
        sequence(chunk.sequence) && duration(chunk.duration) && date(chunk.startedAt)
            && date(chunk.receivedAt) && filename(chunk.filename) && checksum(chunk.sha256)
            && chunk.byteCount > 0 && chunk.byteCount <= Int64(Int32.max)
    }

    // AtomicJSONFile's ISO8601 representation has whole-second precision.
    // Compare timestamps at that precision to preserve duplicate idempotence.
    static func sameSecond(_ first: Date, _ second: Date) -> Bool {
        first.timeIntervalSince1970.rounded(.down) == second.timeIntervalSince1970.rounded(.down)
    }
}
