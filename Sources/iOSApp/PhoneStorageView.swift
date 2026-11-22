import SwiftUI
import UniformTypeIdentifiers

struct PhoneStorageView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var library: PhoneRecordingLibrary
    @ObservedObject var receiver: PhoneConnectivityReceiver
    @StateObject private var storage: PhoneStorageController
    @State private var showCacheConfirmation = false
    @State private var cleanupError: String?
    @State private var showSetup = false
    @State private var diagnosticURL: URL?
    @State private var diagnosticError: String?
    @StateObject private var backup: PhoneBackupController
    @State private var showBackupExport = false
    @State private var showBackupImport = false
    @State private var backupExportMessage: String?

    init(library: PhoneRecordingLibrary, receiver: PhoneConnectivityReceiver, ledger: RecordingSessionLedger, catalog: PhoneSessionCatalog) {
        self.library = library
        self.receiver = receiver
        _storage = StateObject(wrappedValue: PhoneStorageController(recordingsDirectory: library.recordingsDirectory))
        _backup = StateObject(wrappedValue: PhoneBackupController(library: library, ledger: ledger, catalog: catalog))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("手机本地空间") {
                    LabeledContent("原始录音", value: bytes(storage.snapshot.recordingBytes))
                    LabeledContent("合并导出副本", value: bytes(storage.snapshot.exportBytes))
                    LabeledContent("备份临时副本", value: bytes(storage.snapshot.backupBytes))
                    LabeledContent("可用空间", value: storage.snapshot.availableBytes.map(bytes) ?? "暂不可读取")
                    if storage.isRefreshing { ProgressView("正在读取容量") }
                    Button("刷新存储状态") {
                        library.refreshLocalAvailability()
                        Task { await storage.refresh() }
                    }
                    if !library.unavailableChunkIDs.isEmpty {
                        Text("有 \(library.unavailableChunkIDs.count) 段本地文件缺失或校验异常，请检查原件。")
                            .foregroundStyle(.orange)
                    }
                }
                Section("导出缓存") {
                    Button("清理 7 天前的导出与备份临时副本") { showCacheConfirmation = true }.disabled(backup.isBusy)
                    Text("清理前请确认重要备份已另存。仅清理应用生成的旧临时副本；不会删除录音库原件或你已另存的备份。归档不会释放录音空间。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = cleanupError ?? storage.message { Text(message).font(.caption) }
                }
                Section("检查本地录音") {
                    if library.isCheckingIntegrity {
                        ProgressView("正在校验全部分段")
                        Button("取消校验") { library.cancelIntegrityCheck() }
                    } else {
                        Button("校验本地录音完整性") { Task { await library.checkLocalIntegrity() } }
                    }
                    Text("逐段检查内容与完整解码，不需要手表在线。检查可能耗时，可随时取消，不会修改原始录音。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = library.integrityMessage { Text(message).font(.caption) }
                    if !library.unavailableChunkIDs.isEmpty {
                        Text("请先检查“文件”中的原件或另存备份。手机确认接收后手表可能已清理对应分段，重试同步不能保证找回这些文件。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("原始录音备份与恢复") {
                    Button("生成完整本地备份") { backupExportMessage = nil; Task { await backup.create() } }
                        .disabled(backup.isBusy || library.chunks.isEmpty)
                    if backup.backupURL != nil {
                        Button("另存备份文件夹") { showBackupExport = true }.disabled(backup.isBusy)
                    }
                    Button("从备份文件夹恢复") { showBackupImport = true }.disabled(backup.isBusy)
                    if backup.isBusy { ProgressView(); Button("取消备份 / 恢复") { backup.cancel() } }
                    if !backup.message.isEmpty { Text(backup.message).font(.caption) }
                    if let message = backup.errorMessage ?? backupExportMessage { Text(message).font(.caption).foregroundStyle(.orange) }
                    Text("备份包含原始音频、校验清单、场次和命名。生成后请另存到“我的 iPhone”其他文件夹、电脑或外部存储；应用内临时副本不等于独立备份。恢复前会校验全部文件；取消后已导入分段保留，可重新选择同一备份继续。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("运行诊断") {
                    Button("允许录音异常提醒") { Task { await receiver.enableCaptureAlerts() } }
                    Text(receiver.alertMessage).font(.caption)
                    Button("请求手表诊断记录") { receiver.requestWatchEvidence(diagnostics: true) }
                    Text(receiver.diagnosticsMessage).font(.caption)
                    if let date = receiver.watchDiagnosticsDate {
                        Text("已收手表诊断：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption)
                    }
                    Button("生成诊断报告") {
                        do {
                            diagnosticError = nil
                            diagnosticURL = nil
                            diagnosticURL = try DiagnosticJournal.shared.export(context: [
                                "scope": "iPhone local events plus last received Watch snapshot when available",
                                "localChunkCount": String(library.chunks.count),
                                "unavailableChunkCount": String(library.unavailableChunkIDs.count),
                                "pendingCleanupCount": String(receiver.pendingCleanupCount),
                                "connection": receiver.connectionText,
                                "lastEvent": receiver.lastEvent,
                                "lastError": receiver.lastError ?? library.lastError ?? "none"
                            ], watch: receiver.watchDiagnostics)
                        } catch { diagnosticError = error.localizedDescription }
                    }
                    if let diagnosticURL { ShareLink("保存或分享诊断报告", item: diagnosticURL) }
                    if let diagnosticError { Text(diagnosticError).foregroundStyle(.orange) }
                    Text("报告含手机端事件和最近收到的手表诊断，标明各自时间，不含音频或转写。先请求手表诊断，收到后重新生成报告；离线时可能需要等待系统安排传输。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("使用帮助") {
                    Button("重新查看首次安装与授权步骤") { showSetup = true }
                    Text("录音在“文件 → 我的 iPhone → 本应用文件夹 → 全天录音”中。应用文件夹通常显示为“全天录音”。")
                    Text("录音不使用 iCloud 同步，原始录音目录也不参与云备份。重要录音请用详情页的导出功能另存一份。")
                    Text("手表首页点按开始，再次点按停止。顶部状态可查看同步和恢复；手机显示“整场已收齐”才代表清单声明的分段全部到达。")
                    Text("合并导出保持详情页打开。手动重试由系统安排传输，不一定立即开始。")
                }
            }
            .navigationTitle("存储与帮助")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await storage.refresh() }
            .sheet(isPresented: $showSetup) { PhoneSetupView(receiver: receiver) }
            .sheet(isPresented: $showBackupExport) {
                if let url = backup.backupURL {
                    BackupExportPicker(url: url) { saved in
                        showBackupExport = false
                        backupExportMessage = saved ? "备份已另存；请保留完整文件夹" : "已取消另存，临时副本仍在应用中"
                    }
                }
            }
            .fileImporter(isPresented: $showBackupImport, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url):
                    Task {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        await backup.restore(from: url)
                    }
                case let .failure(error): backupExportMessage = error.localizedDescription
                }
            }
            .confirmationDialog("确认重要备份已另存，再清理 7 天前的导出和备份临时副本？", isPresented: $showCacheConfirmation, titleVisibility: .visible) {
                Button("清理旧导出缓存", role: .destructive) {
                    do {
                        cleanupError = nil
                        let exports = try storage.clearExpiredExports()
                        let backups = try storage.clearExpiredBackupCopies()
                        cleanupError = "已清理 \(exports) 个旧导出、\(backups) 个旧备份临时副本"
                        Task { await storage.refresh() }
                    } catch { cleanupError = error.localizedDescription }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { library.cancelIntegrityCheck(); backup.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.cancelIntegrityCheck(); backup.cancel() }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
