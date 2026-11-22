import Combine
import Foundation

@MainActor
final class ChunkQueueStore: ObservableObject {
    @Published private(set) var chunks: [RecordingChunk]
    @Published private(set) var recoveryFileCount = 0
    @Published private(set) var persistenceError: String? = nil

    let recordingsDirectory: URL
    private let queueFile: AtomicJSONFile<[RecordingChunk]>
    private let fileManager: FileManager
    private var indexIsReadable = true

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else {
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            root = support.appendingPathComponent("WatchDayRecorder", isDirectory: true)
        }
        recordingsDirectory = root.appendingPathComponent("Chunks", isDirectory: true)
        queueFile = AtomicJSONFile(url: root.appendingPathComponent("chunk-queue.json"))
        chunks = []
        do {
            let loaded = try queueFile.loadIfPresent(default: [])
            guard loaded.allSatisfy(RecordingMetadataValidation.valid),
                  Set(loaded.map(\.id)).count == loaded.count,
                  Set(loaded.map { $0.filename.lowercased() }).count == loaded.count else {
                throw QueueError.invalidMetadata
            }
            chunks = loaded
        } catch {
            indexIsReadable = false
            persistenceError = "录音队列无法读取，已保留原索引，请解锁后重启应用"
        }

        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            persistenceError = "无法创建录音目录：\(error.localizedDescription)"
        }
        if indexIsReadable {
            reconcileDiskState()
        } else {
            refreshRecoveryCount()
        }
    }

    var pendingCount: Int {
        chunks.filter { $0.state != .awaitingAcknowledgement }.count
    }

    var awaitingAcknowledgementCount: Int {
        chunks.filter { $0.state == .awaitingAcknowledgement }.count
    }

    func partialURL(sessionID: UUID, sequence: Int, chunkID: UUID) -> URL {
        let name = "\(sessionID.uuidString)_\(sequence)_\(chunkID.uuidString).partial.m4a"
        return recordingsDirectory.appendingPathComponent(name)
    }

    /// Commits queue metadata before renaming the audio. On relaunch,
    /// `reconcileDiskState` completes a rename interrupted by process death.
    func finalize(
        partialURL: URL,
        chunkID: UUID,
        sessionID: UUID,
        sequence: Int,
        startedAt: Date,
        duration: TimeInterval
    ) throws -> RecordingChunk {
        let filename = partialURL.lastPathComponent.replacingOccurrences(
            of: ".partial.m4a",
            with: ".m4a"
        )
        let finalURL = recordingsDirectory.appendingPathComponent(filename)
        let alreadyFinal = partialURL.standardizedFileURL == finalURL.standardizedFileURL
        guard alreadyFinal || !fileManager.fileExists(atPath: finalURL.path) else {
            throw QueueError.destinationAlreadyExists
        }

        let attributes = try fileManager.attributesOfItem(atPath: partialURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else { throw QueueError.emptyAudioFile }

        let chunk = RecordingChunk(
            id: chunkID,
            sessionID: sessionID,
            sequence: sequence,
            filename: filename,
            startedAt: startedAt,
            duration: duration,
            byteCount: byteCount,
            sha256: try FileChecksum.sha256(of: partialURL)
        )

        guard RecordingMetadataValidation.valid(chunk) else { throw QueueError.invalidMetadata }
        chunks.removeAll { $0.id == chunk.id }
        chunks.append(chunk)
        try persist()

        do {
            if !alreadyFinal { try fileManager.moveItem(at: partialURL, to: finalURL) }
        } catch {
            markFailed(chunk.id, reason: "录音已入队但改名失败：\(error.localizedDescription)")
            throw error
        }
        refreshRecoveryCount()
        return chunk
    }

    func fileURL(for chunk: RecordingChunk) -> URL {
        recordingsDirectory.appendingPathComponent(chunk.filename)
    }

    func markQueued(_ id: UUID, at date: Date = Date()) {
        update(id) {
            $0.state = .queued
            $0.attemptCount = min($0.attemptCount, Int.max - 1) + 1
            $0.lastAttemptAt = date
            $0.lastError = nil
        }
    }

    func markAwaitingAcknowledgement(_ id: UUID, at date: Date = Date()) {
        update(id) {
            $0.state = .awaitingAcknowledgement
            $0.lastAttemptAt = date
            $0.lastError = nil
        }
    }

    func markFailed(_ id: UUID, reason: String, at date: Date = Date()) {
        update(id) {
            $0.state = .failed
            $0.lastAttemptAt = date
            $0.lastError = reason
        }
    }

    func removeAfterAcknowledgement(id: UUID, sha256: String) throws {
        guard let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        let chunk = chunks[index]
        guard chunk.sha256 == sha256 else { throw QueueError.acknowledgementMismatch }

        defer { refreshRecoveryCount() }
        // Commit the index before deleting its source. If persistence fails,
        // keep the file and restore the in-memory record so ACK cleanup can retry.
        let previous = chunks
        chunks.remove(at: index)
        do { try persist() }
        catch { chunks = previous; throw error }
        let url = fileURL(for: chunk)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func retryPersistenceForRecovery() throws { try persist() }

    private func update(_ id: UUID, mutation: (inout RecordingChunk) -> Void) {
        guard let index = chunks.firstIndex(where: { $0.id == id }) else { return }
        mutation(&chunks[index])
        try? persist()
    }

    private func reconcileDiskState() {
        var recovered: [RecordingChunk] = []
        for chunk in chunks {
            let finalURL = fileURL(for: chunk)
            if fileManager.fileExists(atPath: finalURL.path) {
                recovered.append(chunk)
                continue
            }

            let partialURL = partialURL(forFinalFilename: chunk.filename)
            if fileManager.fileExists(atPath: partialURL.path) {
                do {
                    try fileManager.moveItem(at: partialURL, to: finalURL)
                    recovered.append(chunk)
                } catch {
                    var failed = chunk
                    failed.state = .failed
                    failed.lastError = "重启恢复录音改名失败：\(error.localizedDescription)"
                    failed.lastAttemptAt = Date()
                    recovered.append(failed)
                }
            } else {
                var unavailable = chunk
                unavailable.state = .failed
                unavailable.lastError = "本地录音暂不可访问，已保留索引等待恢复"
                recovered.append(unavailable)
            }
        }
        chunks = recovered
        try? persist()
        refreshRecoveryCount()
    }

    private func partialURL(forFinalFilename filename: String) -> URL {
        let partialName: String
        if filename.hasSuffix(".m4a") {
            partialName = String(filename.dropLast(4)) + ".partial.m4a"
        } else {
            partialName = filename + ".partial"
        }
        return recordingsDirectory.appendingPathComponent(partialName)
    }

    func refreshRecoveryCount() {
        let files = (try? fileManager.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        let tracked = Set(chunks.map(\.filename))
        recoveryFileCount = files.filter { url in
            let name = url.lastPathComponent
            return name.contains(".partial.m4a") || (name.hasSuffix(".m4a") && !tracked.contains(name))
        }.count
    }

    func recoveryCandidates() throws -> [URL] {
        let tracked = Set(chunks.map(\.filename))
        return try fileManager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasSuffix(".partial.m4a")
                    || ($0.pathExtension == "m4a" && !tracked.contains($0.lastPathComponent))
            }
    }

    private func persist() throws {
        guard indexIsReadable else { throw QueueError.indexUnavailable }
        chunks.sort {
            if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
            return $0.startedAt < $1.startedAt
        }
        do {
            try queueFile.save(chunks)
            persistenceError = nil
        } catch {
            persistenceError = "无法保存录音队列：\(error.localizedDescription)"
            throw error
        }
    }
}

enum QueueError: LocalizedError {
    case emptyAudioFile
    case acknowledgementMismatch
    case destinationAlreadyExists
    case indexUnavailable
    case invalidMetadata

    var errorDescription: String? {
        switch self {
        case .emptyAudioFile: "录音文件为空"
        case .acknowledgementMismatch: "手机确认信息与本地文件不一致"
        case .destinationAlreadyExists: "录音目标文件已经存在，为避免覆盖已停止"
        case .indexUnavailable: "旧录音索引无法读取，已停止写入以保留恢复机会"
        case .invalidMetadata: "录音元数据无效，已保留原索引和音频"
        }
    }
}
