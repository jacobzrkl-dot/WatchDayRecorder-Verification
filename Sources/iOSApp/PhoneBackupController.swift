import Combine
import Foundation

struct RecordingBackupManifest: Codable, Sendable {
    let schema: Int
    let createdAt: Date
    let chunks: [PhoneRecordingChunk]
    let sessions: [RecordingSessionManifest]
    let catalog: [SessionPresentationMetadata]

    func validate() throws {
        guard schema == 1, RecordingMetadataValidation.date(createdAt), !chunks.isEmpty,
              chunks.count <= 20_000, chunks.allSatisfy(RecordingMetadataValidation.valid),
              Set(chunks.map(\.id)).count == chunks.count,
              Set(chunks.map { $0.filename.lowercased() }).count == chunks.count,
              Set(chunks.map { "\($0.sessionID):\($0.sequence)" }).count == chunks.count,
              sessions.allSatisfy(\.isValid), Set(sessions.map(\.id)).count == sessions.count,
              Set(catalog.map(\.id)).count == catalog.count,
              catalog.allSatisfy({ $0.title.count <= 80 }) else { throw BackupError.invalid }
        for chunk in chunks {
            if let session = sessions.first(where: { $0.id == chunk.sessionID }) {
                guard session.chunks.contains(where: { $0.id == chunk.id && $0.sequence == chunk.sequence && $0.sha256 == chunk.sha256 })
                else { throw BackupError.invalid }
            }
        }
    }
}

enum BackupError: LocalizedError {
    case invalid, insufficientSpace, incomplete(String)
    var errorDescription: String? {
        switch self {
        case .invalid: "备份格式、文件路径或清单不正确，已保留现有录音"
        case .insufficientSpace: "可用空间不足以生成备份，请先另存文件并释放空间"
        case let .incomplete(reason): "恢复未全部完成，可重新选择同一备份继续：\(reason)"
        }
    }
}

@MainActor
final class PhoneBackupController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var backupURL: URL?
    @Published private(set) var restoredCount = 0
    private let library: PhoneRecordingLibrary
    private let ledger: RecordingSessionLedger
    private let catalog: PhoneSessionCatalog
    private let outputRoot: URL
    private var worker: Task<URL, Error>?
    private var cancelled = false

    init(library: PhoneRecordingLibrary, ledger: RecordingSessionLedger, catalog: PhoneSessionCatalog,
         outputRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingBackups")) {
        self.library = library; self.ledger = ledger; self.catalog = catalog; self.outputRoot = outputRoot
    }

    func cancel() { cancelled = true; worker?.cancel() }

    func create() async {
        guard !isBusy else { return }
        isBusy = true; cancelled = false; errorMessage = nil; backupURL = nil
        defer { isBusy = false; worker = nil }
        message = "正在复制并校验原始分段，请保持本页打开"
        let snapshot = RecordingBackupManifest(schema: 1, createdAt: Date(), chunks: library.chunks,
            sessions: ledger.manifests, catalog: catalog.entries)
        let source = library.recordingsDirectory
        let root = outputRoot
        let task = Task.detached(priority: .utility) {
            try snapshot.validate()
            let manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let free = try manager.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
            let required = snapshot.chunks.reduce(Int64(20 * 1024 * 1024)) { $0 + $1.byteCount }
            if let free, free.int64Value < required { throw BackupError.insufficientSpace }
            let directory = root.appendingPathComponent("全天录音备份_\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                for chunk in snapshot.chunks {
                    try Task.checkCancellation()
                    let original = try Self.safeFile(chunk.filename, in: source)
                    let destination = directory.appendingPathComponent(chunk.filename)
                    try manager.copyItem(at: original, to: destination)
                    try await Self.validateAudio(chunk, at: Self.safeFile(chunk.filename, in: directory))
                }
                try AtomicJSONFile<RecordingBackupManifest>(url: directory.appendingPathComponent("backup.json")).save(snapshot)
                return directory
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
        }
        worker = task
        do {
            let result = try await task.value
            guard !cancelled else {
                try? FileManager.default.removeItem(at: result)
                throw CancellationError()
            }
            backupURL = result
            message = "已校验 \(snapshot.chunks.count) 段；请将备份文件夹保存到其他位置"
        } catch { errorMessage = cancelled ? nil : error.localizedDescription; message = cancelled ? "已取消备份" : "备份失败，原件未修改" }
    }

    func restore(from directory: URL) async {
        guard !isBusy else { return }
        isBusy = true; cancelled = false; restoredCount = 0; errorMessage = nil
        defer { isBusy = false }
        message = "正在完整校验备份，校验通过后才导入"
        do {
            let manifestURL = try Self.safeFile("backup.json", in: directory)
            let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32 * 1024 * 1024 else { throw BackupError.invalid }
            let manifest = try JSONDecoder.withISODate().decode(RecordingBackupManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            // Validate every source first. A corrupt late file must not cause
            // a misleading partial-success restore of an invalid backup.
            for chunk in manifest.chunks {
                if cancelled { throw CancellationError() }
                try await Self.validateAudio(chunk, at: Self.safeFile(chunk.filename, in: directory))
            }
            for chunk in manifest.chunks {
                if cancelled { throw CancellationError() }
                message = "正在恢复 \(restoredCount + 1) / \(manifest.chunks.count) 段"
                let source = RecordingChunk(id: chunk.id, sessionID: chunk.sessionID, sequence: chunk.sequence,
                    filename: chunk.filename, startedAt: chunk.startedAt, duration: chunk.duration,
                    byteCount: chunk.byteCount, sha256: chunk.sha256)
                let sourceURL = try Self.safeFile(chunk.filename, in: directory)
                let result = await library.validateAndImport(stagedURL: sourceURL,
                    source: source, shouldContinue: { !self.cancelled && !Task.isCancelled })
                guard result == .accepted else { throw BackupError.incomplete(String(describing: result)) }
                restoredCount += 1
            }
            for session in manifest.sessions { try ledger.merge(session) }
            try catalog.restoreMissing(manifest.catalog)
            message = "已恢复 \(restoredCount) 段及场次信息；原有命名和录音均保留"
        } catch {
            errorMessage = cancelled ? nil : error.localizedDescription
            message = cancelled ? "已取消；已导入的 \(restoredCount) 段保留，可重试继续" : "恢复未完成，已导入 \(restoredCount) 段，现有录音未删除"
        }
    }

    nonisolated private static func safeFile(_ name: String, in directory: URL) throws -> URL {
        guard RecordingMetadataValidation.filename(name) else { throw BackupError.invalid }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == root else { throw BackupError.invalid }
        return url
    }

    nonisolated private static func validateAudio(_ chunk: PhoneRecordingChunk, at url: URL) async throws {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard bytes.map(Int64.init) == chunk.byteCount, try FileChecksum.sha256(of: url) == chunk.sha256 else { throw BackupError.invalid }
        let duration = try await AudioFileValidator.decodedDuration(of: url)
        guard RecordingDurationValidator.isPlausible(expected: chunk.duration, actual: duration) else { throw BackupError.invalid }
    }
}

private extension JSONDecoder {
    static func withISODate() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}
