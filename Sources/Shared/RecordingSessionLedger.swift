import Combine
import Foundation

@MainActor
final class RecordingSessionLedger: ObservableObject {
    @Published private(set) var manifests: [RecordingSessionManifest] = []
    @Published private(set) var lastError: String?
    private let file: AtomicJSONFile<[RecordingSessionManifest]>
    private var isReadable = true

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchDayRecorder", isDirectory: true)
        file = AtomicJSONFile(url: root.appendingPathComponent("session-manifests.json"))
        do {
            let loaded = try file.loadIfPresent(default: [])
            guard loaded.allSatisfy(\.isValid), Set(loaded.map(\.id)).count == loaded.count else {
                throw SessionLedgerError.invalidManifest
            }
            manifests = loaded
        } catch {
            isReadable = false
            lastError = "场次清单无法读取，已保留原件，请解锁后重启"
        }
    }

    func begin(id: UUID, at date: Date) throws {
        guard !manifests.contains(where: { $0.id == id }) else { throw SessionLedgerError.conflict }
        try commit(manifests + [RecordingSessionManifest(
            id: id, startedAt: date, updatedAt: date, endedAt: nil,
            revision: 1, requiresRecovery: false, wasInterrupted: false, chunks: []
        )])
    }

    func retryPersistenceForRecovery() throws { try commit(manifests) }

    func register(_ chunk: RecordingChunk) throws {
        guard let index = manifests.firstIndex(where: { $0.id == chunk.sessionID }) else {
            // Older/orphaned recordings become explicitly interrupted sessions.
            try begin(id: chunk.sessionID, at: chunk.startedAt)
            return try register(chunk)
        }
        var updated = manifests
        let reference = SessionChunkReference(chunk)
        if let existing = updated[index].chunks.first(where: { $0.id == chunk.id }) {
            guard existing == reference else { throw SessionLedgerError.conflict }
            return
        }
        guard !updated[index].chunks.contains(where: { $0.sequence == chunk.sequence }) else {
            throw SessionLedgerError.conflict
        }
        updated[index].chunks.append(reference)
        updated[index].chunks.sort { $0.sequence < $1.sequence }
        updated[index].revision += 1
        updated[index].updatedAt = Date()
        try commit(updated)
    }

    func end(id: UUID, needsRecovery: Bool, interrupted: Bool = false) throws {
        guard let index = manifests.firstIndex(where: { $0.id == id }) else { throw SessionLedgerError.conflict }
        var updated = manifests
        updated[index].endedAt = Date()
        updated[index].updatedAt = Date()
        updated[index].requiresRecovery = needsRecovery
        updated[index].wasInterrupted = updated[index].wasInterrupted || interrupted
        updated[index].revision += 1
        try commit(updated)
    }

    func interruptOpenSessions() throws {
        for manifest in manifests where manifest.endedAt == nil {
            try end(id: manifest.id, needsRecovery: true, interrupted: true)
        }
    }

    func merge(_ manifest: RecordingSessionManifest) throws {
        guard manifest.isValid else { throw SessionLedgerError.invalidManifest }
        var updated = manifests
        if let index = updated.firstIndex(where: { $0.id == manifest.id }) {
            let existing = updated[index]
            if existing.revision > manifest.revision { return }
            let incomingChunks = Dictionary(uniqueKeysWithValues: manifest.chunks.map { ($0.id, $0) })
            guard RecordingMetadataValidation.sameSecond(existing.startedAt, manifest.startedAt),
                  existing.chunks.allSatisfy({ incomingChunks[$0.id] == $0 }),
                  existing.endedAt == nil || manifest.endedAt != nil,
                  !existing.wasInterrupted || manifest.wasInterrupted else {
                throw SessionLedgerError.conflict
            }
            if existing.revision == manifest.revision {
                let sameEnd: Bool
                switch (existing.endedAt, manifest.endedAt) {
                case (nil, nil): sameEnd = true
                case let (first?, second?): sameEnd = RecordingMetadataValidation.sameSecond(first, second)
                default: sameEnd = false
                }
                guard existing.chunks.count == manifest.chunks.count,
                      existing.requiresRecovery == manifest.requiresRecovery,
                      existing.wasInterrupted == manifest.wasInterrupted,
                      RecordingMetadataValidation.sameSecond(existing.updatedAt, manifest.updatedAt), sameEnd else {
                    throw SessionLedgerError.conflict
                }
            }
            updated[index] = manifest
        } else {
            updated.append(manifest)
        }
        try commit(updated)
    }

    private func commit(_ updated: [RecordingSessionManifest]) throws {
        guard isReadable else { throw SessionLedgerError.unavailable }
        guard updated.allSatisfy(\.isValid) else { throw SessionLedgerError.invalidManifest }
        do {
            try file.save(updated)
            manifests = updated
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

enum SessionLedgerError: LocalizedError {
    case invalidManifest, conflict, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidManifest: "录音场次清单格式无效"
        case .conflict: "录音分段与场次清单冲突，原文件已保留"
        case .unavailable: "录音场次清单暂不可访问"
        }
    }
}
