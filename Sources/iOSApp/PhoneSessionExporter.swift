import AVFoundation
import Combine
import Foundation

@MainActor
final class PhoneSessionExporter: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var statusText = ""
    @Published private(set) var exportedURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var requiredSpaceBytes: Int64 = 0
    private var activeExport: AVAssetExportSession?
    private var validationTask: Task<TimeInterval, Error>?
    private var cancelRequested = false
    private let availableBytes: () throws -> Int64?

    init(availableBytes: @escaping () throws -> Int64? = {
        (try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }) { self.availableBytes = availableBytes }

    func cancel() {
        cancelRequested = true
        activeExport?.cancelExport()
        validationTask?.cancel()
    }

    func invalidate() {
        cancel()
        exportedURL = nil
        statusText = "分段或名称已变化，请重新生成导出"
        progress = 0
    }

    func prepare(chunks: [PhoneRecordingChunk], directory: URL, displayName: String? = nil, allowGaps: Bool = false) async {
        guard !isPreparing else { return }
        isPreparing = true
        cancelRequested = false
        errorMessage = nil
        exportedURL = nil
        defer {
            isPreparing = false
            activeExport = nil
            validationTask = nil
        }
        var outputURL: URL?
        do {
            let ordered = try RecordingSessionPlan.orderedChunks(chunks, allowGaps: allowGaps)
            guard ordered.allSatisfy(RecordingMetadataValidation.valid) else { throw ExportError.cannotCreate }
            requiredSpaceBytes = ExportSpaceBudget.requiredBytes(for: ordered)
            if let available = try availableBytes(), available < requiredSpaceBytes {
                throw ExportError.insufficientSpace(requiredSpaceBytes)
            }
            let composition = AVMutableComposition()
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw ExportError.cannotCreate }
            var cursor = CMTime.zero
            for (index, chunk) in ordered.enumerated() {
                try checkCancellation()
                statusText = "正在校验与准备第 \(index + 1) / \(ordered.count) 段"
                progress = Double(index) / Double(ordered.count) * 0.35
                let url = directory.appendingPathComponent(chunk.filename)
                let hash = try await Task.detached(priority: .utility) { try FileChecksum.sha256(of: url) }.value
                guard hash == chunk.sha256 else {
                    throw ExportError.changedSource(chunk.sequence + 1)
                }
                let asset = AVURLAsset(url: url)
                guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw ExportError.changedSource(chunk.sequence + 1)
                }
                let timeRange = try await sourceTrack.load(.timeRange)
                guard timeRange.duration.seconds.isFinite, timeRange.duration.seconds > 0 else {
                    throw ExportError.changedSource(chunk.sequence + 1)
                }
                try checkCancellation()
                try destinationTrack.insertTimeRange(timeRange, of: sourceTrack, at: cursor)
                cursor = CMTimeAdd(cursor, timeRange.duration)
            }
            let exportsDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SessionExports", isDirectory: true)
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm"
            let title = displayName ?? formatter.string(from: ordered[0].startedAt)
            let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
            var safeTitle = ""
            for character in title.components(separatedBy: forbidden).joined(separator: "_") {
                let candidate = safeTitle + String(character)
                guard candidate.utf8.count <= 160 else { break }
                safeTitle = candidate
            }
            if safeTitle.isEmpty { safeTitle = "录音" }
            let scope = allowGaps ? "所选片段_" : ""
            let output = exportsDirectory.appendingPathComponent("录音_\(scope)\(safeTitle)_\(UUID().uuidString).m4a")
            outputURL = output
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                throw ExportError.cannotCreate
            }
            exporter.outputURL = output
            exporter.outputFileType = .m4a
            activeExport = exporter
            let progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = 0.35 + Double(exporter.progress) * 0.5
                    do { try await Task<Never, Never>.sleep(nanoseconds: 250_000_000) }
                    catch { return }
                }
            }
            defer { progressTask.cancel() }
            statusText = "正在生成合并音频，请保持本页打开"
            try checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
            progressTask.cancel()
            try checkCancellation()
            guard exporter.status == .completed else {
                throw exporter.error ?? ExportError.cannotCreate
            }
            let result = AVURLAsset(url: output)
            progress = 0.9
            statusText = "正在完整校验生成结果"
            let playable = try await result.load(.isPlayable)
            try checkCancellation()
            let decoder = Task { try await AudioFileValidator.decodedDuration(of: output) }
            validationTask = decoder
            let duration = try await withTaskCancellationHandler {
                try await decoder.value
            } onCancel: {
                decoder.cancel()
            }
            guard playable, RecordingDurationValidator.isPlausible(expected: cursor.seconds, actual: duration) else {
                throw ExportError.invalidResult
            }
            try checkCancellation()
            exportedURL = output
            progress = 1
            statusText = allowGaps ? "已导出所选 \(ordered.count) 段；未补入缺段或时间空档" : "已生成 \(ordered.count) 段合并音频，可保存到文件或分享"
        } catch {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            errorMessage = cancelRequested ? nil : error.localizedDescription
            statusText = cancelRequested ? "已取消导出" : "导出失败，原始分段已保留"
        }
    }

    private func checkCancellation() throws {
        if cancelRequested || Task.isCancelled { throw CancellationError() }
    }
}

private enum ExportError: LocalizedError {
    case cannotCreate
    case changedSource(Int)
    case invalidResult
    case insufficientSpace(Int64)

    var errorDescription: String? {
        switch self {
        case .cannotCreate: "无法生成合并文件，请检查手机空间后重试"
        case let .changedSource(sequence): "第 \(sequence) 段缺失、损坏或已被修改，请先重新同步"
        case .invalidResult: "合并文件校验失败，未提供导出；原始分段已保留"
        case let .insufficientSpace(bytes): "导出前需预留约 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) 空间；可先备份原始分段，不必合并"
        }
    }
}
