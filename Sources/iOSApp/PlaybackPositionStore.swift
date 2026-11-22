import Foundation

@MainActor
final class PlaybackPositionStore {
    private struct Position: Codable {
        let id: UUID
        let sha256: String
        let seconds: TimeInterval
        let updatedAt: Date
    }
    private let file: AtomicJSONFile<[Position]>
    private var positions: [Position] = []
    private var readable = true
    private(set) var lastError: String?

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchDayRecorder")
        file = AtomicJSONFile(url: root.appendingPathComponent("playback-positions.json"))
        do {
            let loaded = try file.loadIfPresent(default: [])
            guard loaded.count <= 500, Set(loaded.map(\.id)).count == loaded.count,
                  loaded.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 && RecordingMetadataValidation.checksum($0.sha256) && RecordingMetadataValidation.date($0.updatedAt) })
            else { throw CocoaError(.fileReadCorruptFile) }
            positions = loaded
        } catch { readable = false; lastError = "播放进度无法读取，原始音频不受影响" }
    }

    func position(for id: UUID, sha256: String, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, let saved = positions.first(where: { $0.id == id && $0.sha256 == sha256 }),
              saved.seconds > 0, saved.seconds < duration - 2 else { return 0 }
        return saved.seconds
    }

    func remember(id: UUID, sha256: String, seconds: TimeInterval, duration: TimeInterval) {
        guard readable, seconds.isFinite, duration.isFinite, duration > 0,
              RecordingMetadataValidation.checksum(sha256) else { return }
        var updated = positions.filter { $0.id != id }
        if seconds > 0, seconds < duration - 2 {
            updated.append(Position(id: id, sha256: sha256, seconds: seconds, updatedAt: Date()))
        }
        updated.sort { $0.updatedAt > $1.updatedAt }
        updated = Array(updated.prefix(500))
        do { try file.save(updated); positions = updated; lastError = nil }
        catch { lastError = "播放进度未能保存，音频仍可播放" }
    }
}
