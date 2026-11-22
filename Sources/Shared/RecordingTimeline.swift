import Foundation

struct RecordingTimeGap: Identifiable, Equatable {
    var id: Int { nextSequence }
    let start: Date
    let end: Date
    let nextSequence: Int
    let missingSegments: Int
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum RecordingTimeline {
    // File timestamps and decoded audio duration estimate gaps. They cannot
    // measure physical microphone continuity or explain clock changes.
    static func gaps(in chunks: [PhoneRecordingChunk]) -> [RecordingTimeGap] {
        guard Set(chunks.map(\.sessionID)).count <= 1 else { return [] }
        let ordered = chunks.filter(RecordingMetadataValidation.valid).sorted { $0.sequence < $1.sequence }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, next in
            let end = previous.startedAt.addingTimeInterval(previous.duration)
            guard next.startedAt.timeIntervalSince(end) > 2 else { return nil }
            return RecordingTimeGap(start: end, end: next.startedAt, nextSequence: next.sequence,
                missingSegments: max(0, next.sequence - previous.sequence - 1))
        }
    }
}
