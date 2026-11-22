import AVFoundation
import Combine
import Foundation

@MainActor
final class WatchRecoveryController: ObservableObject {
    @Published private(set) var isRecovering = false
    @Published private(set) var statusText = "检查并恢复意外中断留下的录音"
    @Published private(set) var failures: [String] = []
    private let store: ChunkQueueStore
    private let ledger: RecordingSessionLedger
    private let recorder: ChunkedRecorder
    private let scheduleTransfers: () -> Void

    init(store: ChunkQueueStore, ledger: RecordingSessionLedger, recorder: ChunkedRecorder, scheduleTransfers: @escaping () -> Void) {
        self.store = store
        self.ledger = ledger
        self.recorder = recorder
        self.scheduleTransfers = scheduleTransfers
    }

    func recover() async {
        guard !isRecovering, recorder.beginRecovery() else {
            statusText = "请先停止录音并等待保存完成，再执行恢复"
            return
        }
        isRecovering = true
        failures = []
        defer {
            store.refreshRecoveryCount()
            recorder.endRecovery()
            isRecovering = false
        }
        var failedSessions: Set<UUID> = []
        var recoveredCount = 0
        do {
            // Historical write errors are retryable. Unreadable indexes still
            // fail closed inside these methods and cannot become empty indexes.
            try store.retryPersistenceForRecovery()
            try ledger.retryPersistenceForRecovery()
            let candidates = try store.recoveryCandidates().sorted {
                let left = RecordingRecoveryName(url: $0)
                let right = RecordingRecoveryName(url: $1)
                return (left?.sequence ?? 0) < (right?.sequence ?? 0)
            }
            for url in candidates {
                guard let identity = RecordingRecoveryName(url: url) else {
                    failures.append("文件名无法识别，已保留：\(url.lastPathComponent)")
                    continue
                }
                statusText = "正在恢复第 \(identity.sequence + 1) 段"
                do {
                    let duration = try await AudioFileValidator.decodedDuration(of: url)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let startedAt = attributes[.creationDate] as? Date ?? Date()
                    let chunk = try store.finalize(
                        partialURL: url, chunkID: identity.chunkID,
                        sessionID: identity.sessionID, sequence: identity.sequence,
                        startedAt: startedAt, duration: duration
                    )
                    try ledger.register(chunk)
                    recoveredCount += 1
                } catch {
                    failedSessions.insert(identity.sessionID)
                    failures.append("第 \(identity.sequence + 1) 段：\(error.localizedDescription)。原件已保留")
                }
            }
            // Finalization may have succeeded before a ledger write failed.
            // Repair those references before permitting any transfer.
            for chunk in store.chunks.sorted(by: { $0.sequence < $1.sequence }) {
                guard ledger.manifests.first(where: { $0.id == chunk.sessionID })?.chunks
                    .contains(SessionChunkReference(chunk)) != true else { continue }
                do {
                    let url = store.fileURL(for: chunk)
                    guard try FileChecksum.sha256(of: url) == chunk.sha256 else { throw SessionLedgerError.conflict }
                    _ = try await AudioFileValidator.decodedDuration(of: url)
                    try ledger.register(chunk)
                } catch {
                    failedSessions.insert(chunk.sessionID)
                    failures.append("第 \(chunk.sequence + 1) 段索引恢复失败：\(error.localizedDescription)")
                }
            }
            let remainingSessions = Set(try store.recoveryCandidates().compactMap {
                RecordingRecoveryName(url: $0)?.sessionID
            })
            for manifest in ledger.manifests where manifest.requiresRecovery || manifest.endedAt == nil {
                let hasGap = !ChunkSequenceValidator.isContinuous(manifest.chunks.map(\.sequence))
                try ledger.end(
                    id: manifest.id,
                    needsRecovery: hasGap || failedSessions.contains(manifest.id) || remainingSessions.contains(manifest.id),
                    interrupted: true
                )
            }
            scheduleTransfers()
            statusText = "已恢复 \(recoveredCount) 段，\(failures.count) 项需要检查"
        } catch {
            failures.append(error.localizedDescription)
            statusText = "恢复未完成，原文件均保留"
        }
    }

}
