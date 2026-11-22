import AVFoundation
import Combine
import Foundation

@MainActor
final class PhoneRecordingLibrary: ObservableObject {
    @Published private(set) var chunks: [PhoneRecordingChunk]
    @Published private(set) var lastError: String?
    @Published private(set) var unavailableChunkIDs: Set<UUID> = []
    @Published private(set) var isCheckingIntegrity = false
    @Published private(set) var integrityMessage: String?

    let recordingsDirectory: URL

    private let indexFile: AtomicJSONFile<[PhoneRecordingChunk]>
    private let integrityFile: AtomicJSONFile<[UUID]>
    private var corruptChunkIDs: Set<UUID> = []
    private var integrityWorker: Task<Set<UUID>, Error>?
    private let fileManager: FileManager
    private var indexIsReadable = true

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let documents = rootDirectory?.appendingPathComponent("Documents", isDirectory: true)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = rootDirectory?.appendingPathComponent("Support", isDirectory: true)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        recordingsDirectory = documents.appendingPathComponent("全天录音", isDirectory: true)
        indexFile = AtomicJSONFile(
            url: support
                .appendingPathComponent("WatchDayRecorder", isDirectory: true)
                .appendingPathComponent("phone-library.json")
        )
        integrityFile = AtomicJSONFile(url: support.appendingPathComponent("WatchDayRecorder/local-integrity.json"))
        chunks = []
        do { corruptChunkIDs = Set(try integrityFile.loadIfPresent(default: [])) }
        catch { integrityMessage = "上次校验记录无法读取，请重新校验本地录音" }
        do {
            let loaded = try indexFile.loadIfPresent(default: [])
            guard loaded.allSatisfy(RecordingMetadataValidation.valid),
                  Set(loaded.map(\.id)).count == loaded.count,
                  Set(loaded.map { $0.filename.lowercased() }).count == loaded.count,
                  Set(loaded.map { "\($0.sessionID):\($0.sequence)" }).count == loaded.count else {
                throw ImportError.conflictingIdentity
            }
            chunks = loaded
        } catch {
            indexIsReadable = false
            lastError = "旧录音索引无法读取，已保留原文件，请解锁后重启应用"
        }
        do {
            try fileManager.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
            var localDirectory = recordingsDirectory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try localDirectory.setResourceValues(resourceValues)
        } catch {
            lastError = "无法准备手机本地录音目录：\(error.localizedDescription)"
        }
        if indexIsReadable { reconcileIndex() }
    }

    func fileURL(for chunk: PhoneRecordingChunk) -> URL {
        recordingsDirectory.appendingPathComponent(chunk.filename)
    }

    func containsVerifiedCopy(of chunk: RecordingChunk) -> Bool {
        guard let existing = chunks.first(where: { $0.id == chunk.id }) else { return false }
        let url = fileURL(for: existing)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard existing.sha256 == chunk.sha256 else { return false }
        return (try? FileChecksum.sha256(of: url)) == chunk.sha256
    }

    func validateAndImport(
        stagedURL: URL,
        source chunk: RecordingChunk,
        shouldContinue: () -> Bool = { !Task.isCancelled }
    ) async -> ImportResult {
        guard indexIsReadable else {
            return .rejected("旧录音索引无法读取，请解锁后重启应用")
        }
        guard shouldContinue() else { return .deferred("等待前台继续校验") }
        do { try validateIdentity(of: chunk) }
        catch {
            lastError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
        if containsVerifiedCopy(of: chunk) {
            do {
                // Older indexes may have been written using container metadata
                // only. Revalidate the local audio before ACKing any duplicate.
                guard let existing = chunks.first(where: { $0.id == chunk.id }) else {
                    throw ImportError.unplayable
                }
                let duration = try await AudioFileValidator.decodedDuration(of: fileURL(for: existing))
                guard shouldContinue() else { return .deferred("等待前台继续校验已有录音") }
                guard RecordingDurationValidator.isPlausible(expected: chunk.duration, actual: duration) else {
                    throw ImportError.durationMismatch(expected: chunk.duration, actual: duration)
                }
                // Recommit even a duplicate before ACK, including an index
                // recovered from its backup after an interrupted write.
                try sortAndPersist()
                unavailableChunkIDs.remove(chunk.id)
                corruptChunkIDs.remove(chunk.id)
                saveIntegrityStatus()
                lastError = unavailableChunkIDs.isEmpty ? nil : "部分录音暂不可访问，已保留索引，请检查本地文件"
                return .accepted
            } catch is CancellationError {
                return .deferred("校验已暂停，录音将在前台继续处理")
            } catch {
                lastError = error.localizedDescription
                return .rejected(error.localizedDescription)
            }
        }

        do {
            let destinationName = destinationFilename(for: chunk)
            let destinationURL = recordingsDirectory.appendingPathComponent(destinationName)
            // AVFoundation's format discovery also uses the filename suffix.
            // Keep M4A as the final extension while hiding the uncommitted copy.
            let preparedURL = recordingsDirectory.appendingPathComponent(".importing-\(UUID().uuidString).m4a")
            defer { try? fileManager.removeItem(at: preparedURL) }
            // Validate the exact private copy that will be committed, rather
            // than trusting a source that can change across asynchronous reads.
            // The durable inbox/external backup is retained throughout.
            try fileManager.copyItem(at: stagedURL, to: preparedURL)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: preparedURL.path
            )
            let attributes = try fileManager.attributesOfItem(atPath: preparedURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ImportError.unplayable }
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount == chunk.byteCount else {
                throw ImportError.sizeMismatch(expected: chunk.byteCount, actual: byteCount)
            }

            let actualHash = try FileChecksum.sha256(of: preparedURL)
            guard actualHash == chunk.sha256 else { throw ImportError.checksumMismatch }

            let asset = AVURLAsset(url: preparedURL)
            let isPlayable = try await asset.load(.isPlayable)
            let loadedDuration = try await asset.load(.duration).seconds
            guard shouldContinue() else { return .deferred("后台处理时间已到，录音将在前台继续校验") }
            guard isPlayable, loadedDuration.isFinite, loadedDuration > 0 else {
                throw ImportError.unplayable
            }

            let decodedDuration = try await AudioFileValidator.decodedDuration(of: preparedURL)
            guard shouldContinue() else { return .deferred("后台处理时间已到，录音将在前台继续校验") }

            guard RecordingDurationValidator.isPlausible(
                expected: chunk.duration,
                actual: decodedDuration
            ) else {
                throw ImportError.durationMismatch(
                    expected: chunk.duration,
                    actual: decodedDuration
                )
            }

            // The main actor can be reentered while awaiting audio loading.
            // Recheck before replacing any destination or committing an index.
            try validateIdentity(of: chunk)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: preparedURL)
            } else {
                try fileManager.moveItem(at: preparedURL, to: destinationURL)
            }

            let imported = PhoneRecordingChunk(
                id: chunk.id,
                sessionID: chunk.sessionID,
                sequence: chunk.sequence,
                filename: destinationName,
                startedAt: chunk.startedAt,
                duration: decodedDuration,
                byteCount: byteCount,
                sha256: actualHash,
                receivedAt: Date()
            )
            let previousChunks = chunks
            chunks.removeAll { $0.id == chunk.id }
            chunks.append(imported)
            do {
                try sortAndPersist()
            } catch {
                // Do not ACK a file whose library index is only in memory.
                // The destination copy remains recoverable in Documents and
                // the durable inbox copy is retained for another attempt.
                chunks = previousChunks
                throw error
            }
            unavailableChunkIDs.remove(chunk.id)
            corruptChunkIDs.remove(chunk.id)
            saveIntegrityStatus()
            lastError = unavailableChunkIDs.isEmpty ? nil : "部分录音暂不可访问，已保留索引，请检查本地文件"
            return .accepted
        } catch is CancellationError {
            return .deferred("校验已暂停，录音将在前台继续处理")
        } catch {
            lastError = error.localizedDescription
            return .rejected(error.localizedDescription)
        }
    }

    private func destinationFilename(for chunk: RecordingChunk) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: chunk.startedAt)
        let sequence = String(format: "%03d", chunk.sequence + 1)
        return "\(stamp)_第\(sequence)段_\(chunk.id.uuidString).m4a"
    }

    private func reconcileIndex() {
        refreshLocalAvailability()
    }

    func refreshLocalAvailability() {
        unavailableChunkIDs = corruptChunkIDs.intersection(Set(chunks.map(\.id))).union(Set(chunks.filter {
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL(for: $0).path),
                  let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
                  let bytes = (attributes[.size] as? NSNumber)?.int64Value else { return true }
            return bytes != $0.byteCount
        }.map(\.id)))
        if !unavailableChunkIDs.isEmpty {
            lastError = "部分录音暂不可访问，已保留索引，请检查本地文件"
        } else if lastError == "部分录音暂不可访问，已保留索引，请检查本地文件" {
            lastError = nil
        }
    }

    func cancelIntegrityCheck() { integrityWorker?.cancel() }

    func checkLocalIntegrity() async {
        guard !isCheckingIntegrity else { return }
        guard indexIsReadable else {
            integrityMessage = "录音索引无法读取，暂不能校验，请解锁并重启应用"
            return
        }
        guard !Task.isCancelled else { integrityMessage = "已取消校验"; return }
        isCheckingIntegrity = true
        integrityMessage = "正在完整校验本地录音，可随时取消"
        defer { isCheckingIntegrity = false; integrityWorker = nil }
        let snapshot = chunks
        let directory = recordingsDirectory
        let worker = Task.detached(priority: .utility) { () throws -> Set<UUID> in
            var failed: Set<UUID> = []
            for chunk in snapshot {
                try Task.checkCancellation()
                do {
                    let url = directory.appendingPathComponent(chunk.filename)
                    guard try FileChecksum.sha256(of: url) == chunk.sha256 else { throw ImportError.checksumMismatch }
                    let duration = try await AudioFileValidator.decodedDuration(of: url)
                    guard RecordingDurationValidator.isPlausible(expected: chunk.duration, actual: duration) else {
                        throw ImportError.unplayable
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { failed.insert(chunk.id) }
            }
            try Task.checkCancellation()
            return failed
        }
        integrityWorker = worker
        do {
            let failed = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard chunks == snapshot else {
                integrityMessage = "校验期间录音列表有更新，请重新校验"
                return
            }
            corruptChunkIDs = failed
            refreshLocalAvailability()
            try integrityFile.save(Array(failed))
            integrityMessage = failed.isEmpty ? "已校验 \(snapshot.count) 段，未发现异常" : "已校验 \(snapshot.count) 段，\(failed.count) 段缺失或校验异常；原文件和索引均保留"
        } catch is CancellationError { integrityMessage = "已取消校验，原文件未修改" }
        catch { integrityMessage = "校验结果未能保存：\(error.localizedDescription)" }
    }

    private func saveIntegrityStatus() {
        do { try integrityFile.save(Array(corruptChunkIDs)) }
        catch { integrityMessage = "校验状态未能保存，请重新校验本地录音" }
    }

    private func validateIdentity(of chunk: RecordingChunk) throws {
        guard RecordingMetadataValidation.valid(chunk) else { throw ImportError.unplayable }
        if let existing = chunks.first(where: { $0.id == chunk.id }),
           existing.sessionID != chunk.sessionID || existing.sequence != chunk.sequence || existing.sha256 != chunk.sha256 {
            throw ImportError.conflictingIdentity
        }
        guard !chunks.contains(where: {
            $0.sessionID == chunk.sessionID && $0.sequence == chunk.sequence && $0.id != chunk.id
        }) else { throw ImportError.conflictingIdentity }
    }

    private func sortAndPersist() throws {
        chunks.sort {
            if $0.startedAt == $1.startedAt { return $0.sequence < $1.sequence }
            return $0.startedAt > $1.startedAt
        }
        try indexFile.save(chunks)
    }
}

enum ImportResult: Equatable {
    case accepted
    case rejected(String)
    case deferred(String)
}

enum ImportError: LocalizedError {
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case unplayable
    case durationMismatch(expected: TimeInterval, actual: TimeInterval)
    case conflictingIdentity

    var errorDescription: String? {
        switch self {
        case let .sizeMismatch(expected, actual):
            "文件大小不一致：应为 \(expected)，实际 \(actual)"
        case .checksumMismatch:
            "SHA-256 校验不一致"
        case .unplayable:
            "系统无法解码这个音频文件"
        case .conflictingIdentity:
            "同一录音编号出现不同内容或场次，已保留已有录音并拒绝覆盖"
        case let .durationMismatch(expected, actual):
            "录音时长异常：手表 \(Int(expected)) 秒，手机 \(Int(actual)) 秒"
        }
    }
}
