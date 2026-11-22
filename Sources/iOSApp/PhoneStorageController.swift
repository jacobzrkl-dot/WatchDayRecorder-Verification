import Combine
import Foundation

struct PhoneStorageSnapshot: Sendable {
    var recordingBytes: Int64 = 0
    var exportBytes: Int64 = 0
    var backupBytes: Int64 = 0
    var availableBytes: Int64?
}

@MainActor
final class PhoneStorageController: ObservableObject {
    @Published private(set) var snapshot = PhoneStorageSnapshot()
    @Published private(set) var isRefreshing = false
    @Published private(set) var message: String?
    private let recordingsDirectory: URL
    private let exportsDirectory: URL
    private let backupsDirectory: URL

    init(recordingsDirectory: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.recordingsDirectory = recordingsDirectory
        exportsDirectory = temporaryDirectory.appendingPathComponent("SessionExports", isDirectory: true)
        backupsDirectory = temporaryDirectory.appendingPathComponent("RecordingBackups", isDirectory: true)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let recordings = recordingsDirectory
        let exports = exportsDirectory
        let backups = backupsDirectory
        do {
            snapshot = try await Task.detached(priority: .utility) {
                let values = try recordings.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return PhoneStorageSnapshot(
                    recordingBytes: try Self.folderSize(recordings),
                    exportBytes: try Self.folderSize(exports),
                    backupBytes: try Self.folderSize(backups),
                    availableBytes: values.volumeAvailableCapacityForImportantUsage
                )
            }.value
            if message?.hasPrefix("无法读取存储信息：") == true { message = nil }
        } catch {
            message = "无法读取存储信息：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func clearExpiredBackupCopies(now: Date = Date()) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: backupsDirectory.path) else { return 0 }
        let values = try backupsDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let backupRoot = backupsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let originals = recordingsDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard values.isDirectory == true, values.isSymbolicLink != true,
              backupRoot != originals, !backupRoot.path.hasPrefix(originals.path + "/"),
              !originals.path.hasPrefix(backupRoot.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let prefix = "全天录音备份_"
        var removed = 0
        for url in try manager.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) {
            guard url.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
            let entry = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard entry.isDirectory == true, entry.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == backupRoot,
                  let modified = entry.contentModificationDate, modified < cutoff else { continue }
            try manager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    @discardableResult
    func clearExpiredExports(now: Date = Date()) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: exportsDirectory.path) else {
            message = "没有可清理的旧导出副本"
            return 0
        }
        let rootValues = try exportsDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let exportsRoot = exportsDirectory.resolvingSymlinksInPath().standardizedFileURL
        let originalsRoot = recordingsDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              exportsRoot != originalsRoot,
              !exportsRoot.path.hasPrefix(originalsRoot.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let files = try manager.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        )
        var removed = 0
        for url in files {
            guard url.deletingLastPathComponent().standardizedFileURL == exportsDirectory.standardizedFileURL,
                  url.lastPathComponent.hasPrefix("录音_"), url.pathExtension == "m4a" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try manager.removeItem(at: url)
            removed += 1
        }
        message = "已清理 \(removed) 个旧导出副本，原始录音未删除"
        return removed
    }

    nonisolated private static func folderSize(_ directory: URL) throws -> Int64 {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        var readError: Error?
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in readError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var size: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        if let readError { throw readError }
        return size
    }
}
