import Combine
import Foundation
import UIKit
import UserNotifications
@preconcurrency import WatchConnectivity

@MainActor
final class PhoneConnectivityReceiver: NSObject, ObservableObject {
    @Published private(set) var connectionText = "正在启用手表连接…"
    @Published private(set) var lastEvent = "等待手表录音"
    @Published private(set) var isActivated = false
    @Published private(set) var isRetrying = false
    @Published private(set) var lastError: String?
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var pendingCleanupCount = 0
    @Published private(set) var lastWatchStatus: WatchCaptureStatus?
    @Published private(set) var watchDiagnosticsDate: Date?
    @Published private(set) var diagnosticsMessage = "尚未收到手表诊断"
    @Published private(set) var alertMessage = "异常提醒需手动授权；离线时不能保证及时送达"
    @Published private var activationFailed = false

    var setupState: CompanionSetupState {
        .resolve(supported: session != nil, activated: isActivated, failed: activationFailed,
                 paired: isPaired, installed: isWatchAppInstalled)
    }

    private let library: PhoneRecordingLibrary
    private let ledger: RecordingSessionLedger
    // The WatchConnectivity file URL must be copied synchronously from its
    // nonisolated delegate callback before the framework invalidates it.
    private nonisolated let inbox: PhoneIncomingStore
    private nonisolated let evidence: CompanionEvidenceStore
    private let session: WCSession?
    private var processingChunkIDs: Set<UUID> = []
    private var isDrainingInbox = false
    private var cleanupFailures: [UUID: String] = [:]
    private var cleanupWarning: String?
    private let acknowledgementSender: ((RecordingChunk, Bool, String?) -> Bool)?
    private let leaseFactory: @MainActor () -> any ImportProcessingLease

    init(
        library: PhoneRecordingLibrary,
        ledger: RecordingSessionLedger,
        inbox: PhoneIncomingStore = PhoneIncomingStore(),
        session: WCSession? = WCSession.isSupported() ? .default : nil,
        acknowledgementSender: ((RecordingChunk, Bool, String?) -> Bool)? = nil,
        leaseFactory: @escaping @MainActor () -> any ImportProcessingLease = { BackgroundImportLease() },
        evidence: CompanionEvidenceStore = CompanionEvidenceStore()
    ) {
        self.library = library
        self.ledger = ledger
        self.inbox = inbox
        self.session = session
        self.acknowledgementSender = acknowledgementSender
        self.leaseFactory = leaseFactory
        self.evidence = evidence
        lastWatchStatus = evidence.status()
        watchDiagnosticsDate = evidence.diagnostics()?.generatedAt
        super.init()
        session?.delegate = self
        session?.activate()
        if session == nil { connectionText = "当前环境无法连接 Apple Watch，请在 iPhone 真机使用" }
    }

    private func drainInbox() async {
        guard !isDrainingInbox else { return }
        isDrainingInbox = true
        defer { isDrainingInbox = false }
        if let cleanupWarning, lastError == cleanupWarning { lastError = nil }
        cleanupWarning = nil
        let pendingIDs = Set(inbox.pending().map(\.id))
        cleanupFailures = cleanupFailures.filter { pendingIDs.contains($0.key) }
        pendingCleanupCount = cleanupFailures.count
        var attempted: Set<UUID> = []
        // Refresh the snapshot after every delivery: arrivals during an await
        // join this same serial drain. A retained cleanup failure is attempted
        // only once per pass so it cannot block unrelated recordings.
        while let delivery = inbox.pending().first(where: { !attempted.contains($0.id) }) {
            attempted.insert(delivery.id)
            if await process(delivery) == .paused { break }
        }
        if pendingCleanupCount > 0 {
            cleanupWarning = "有 \(pendingCleanupCount) 项收件记录待清理：\(cleanupFailures.values.sorted().first ?? "")"
            lastError = cleanupWarning
            lastEvent = "已继续处理其他录音；待清理项目可重试"
        }
    }

    func resumePendingImports() async { await drainInbox() }

    func refreshDeviceStatus() {
        guard let session, session.activationState == .activated else {
            isPaired = false
            isWatchAppInstalled = false
            return
        }
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
    }

    var supportsWatchConnectivity: Bool { session != nil }
    var watchDiagnostics: DiagnosticSnapshot? { evidence.diagnostics() }

    func enableCaptureAlerts() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            alertMessage = granted ? "已允许异常提醒；只提醒手表明确报告的中断或错误，离线不等于停止" : "未允许通知，可在 iPhone 设置中启用"
        } catch { alertMessage = "提醒授权失败：\(error.localizedDescription)" }
    }

    private func notifyCaptureProblem(_ status: WatchCaptureStatus, previous: WatchCaptureStatus?) async {
        guard status.shouldNotify(after: previous) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        guard lastWatchStatus?.timestamp == status.timestamp, lastWatchStatus?.mode == status.mode else { return }
        let content = UNMutableNotificationContent()
        content.title = "请检查手表录音"
        content.body = "手表在 \(status.timestamp.formatted(date: .omitted, time: .standard)) 报告录音中断或异常，请打开手表确认当前状态。"
        content.sound = .default
        do { try await center.add(UNNotificationRequest(identifier: "WatchDayRecorder.captureProblem", content: content, trigger: nil)) }
        catch { DiagnosticJournal.shared.record("phone_status", "notification_failed", details: ["reason": error.localizedDescription]) }
    }

    func requestWatchEvidence(diagnostics: Bool) {
        guard let session, session.activationState == .activated else {
            session?.activate()
            diagnosticsMessage = "正在启用连接，就绪后请重试；录音不会被修改"
            return
        }
        let kind = diagnostics ? TransferProtocol.diagnosticsRequestKind : TransferProtocol.statusRequestKind
        if !session.outstandingUserInfoTransfers.contains(where: { TransferProtocol.isKind(kind, $0.userInfo) }) {
            session.transferUserInfo(TransferProtocol.request(kind))
        }
        diagnosticsMessage = diagnostics ? "手表诊断请求已排队，收到后自动合入报告" : "手表状态请求已排队；离线时需等待重连"
    }

    private func acknowledgeManifests(only id: UUID? = nil) {
        guard let session, session.activationState == .activated else { return }
        let outstanding = Set(session.outstandingUserInfoTransfers.compactMap {
            TransferProtocol.parseManifestAcknowledgement($0.userInfo).map { "\($0.id):\($0.revision)" }
        })
        for manifest in ledger.manifests where (id == nil || manifest.id == id)
            && !outstanding.contains("\(manifest.id):\(manifest.revision)") {
            session.transferUserInfo(TransferProtocol.manifestAcknowledgement(manifest))
        }
    }

    func retrySync() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        lastError = nil
        library.refreshLocalAvailability()
        await drainInbox()
        refreshDeviceStatus()
        guard let session, session.activationState == .activated else {
            activationFailed = false
            session?.activate()
            lastEvent = "正在重新启用连接，就绪后请再次重试"
            return
        }
        acknowledgeManifests()
        guard setupState == .ready else {
            lastEvent = setupState.guidance
            return
        }
        session.transferUserInfo(TransferProtocol.retryRequest())
        lastEvent = "已排队请求手表重传；系统安排传输后自动接收"
    }

    private enum ProcessingOutcome { case processed, retained, paused }

    private func process(_ delivery: PhoneIncomingDelivery) async -> ProcessingOutcome {
        let chunk = delivery.chunk
        guard processingChunkIDs.insert(chunk.id).inserted else { return .paused }
        defer { _ = processingChunkIDs.remove(chunk.id) }

        let lease = leaseFactory()
        defer { lease.finish() }
        lastEvent = "正在校验第 \(chunk.sequence + 1) 段"
        let importTask = Task { @MainActor in
            await library.validateAndImport(
                stagedURL: inbox.audioURL(for: delivery), source: chunk,
                shouldContinue: { !lease.isExpired && !Task.isCancelled }
            )
        }
        lease.onExpiration = { importTask.cancel() }
        let result = await withTaskCancellationHandler {
            await importTask.value
        } onCancel: {
            importTask.cancel()
        }
        let acknowledgementQueued: Bool
        switch result {
        case .accepted:
            DiagnosticJournal.shared.record("phone_import", "accepted", details: ["sequence": String(chunk.sequence), "bytes": String(chunk.byteCount)])
            lastError = nil
            lastEvent = "第 \(chunk.sequence + 1) 段已保存到本机"
            acknowledgementQueued = sendAcknowledgement(
                for: chunk,
                accepted: true,
                reason: nil
            )
        case let .rejected(reason):
            DiagnosticJournal.shared.record("phone_import", "rejected", details: ["reason": reason])
            lastError = reason
            lastEvent = "第 \(chunk.sequence + 1) 段校验失败"
            acknowledgementQueued = sendAcknowledgement(
                for: chunk,
                accepted: false,
                reason: reason
            )
        case let .deferred(reason):
            DiagnosticJournal.shared.record("phone_import", "deferred", details: ["reason": reason])
            lastEvent = reason
            return .paused
        }
        guard acknowledgementQueued else {
            DiagnosticJournal.shared.record("phone_import", "ack_not_queued")
            lastEvent = "等待连接恢复后确认第 \(chunk.sequence + 1) 段"
            return .paused
        }
        do {
            try inbox.remove(delivery)
            cleanupFailures.removeValue(forKey: delivery.id)
            pendingCleanupCount = cleanupFailures.count
        } catch {
            cleanupFailures[delivery.id] = error.localizedDescription
            DiagnosticJournal.shared.record("phone_import", "cleanup_failed", details: ["reason": error.localizedDescription])
            pendingCleanupCount = cleanupFailures.count
            lastError = error.localizedDescription
            lastEvent = "录音已处理，但收件箱清理失败"
            return .retained
        }
        return .processed
    }

    private func sendAcknowledgement(
        for chunk: RecordingChunk,
        accepted: Bool,
        reason: String?
    ) -> Bool {
        if let acknowledgementSender { return acknowledgementSender(chunk, accepted, reason) }
        guard let session, session.activationState == .activated else { return false }
        let payload = TransferProtocol.acknowledgement(
            chunkID: chunk.id,
            sha256: chunk.sha256,
            accepted: accepted,
            reason: reason
        )

        // A single durable ACK is idempotent and survives temporary unreachability.
        session.transferUserInfo(payload)
        return true
    }
}
extension PhoneConnectivityReceiver: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if TransferProtocol.hasUnsupportedVersion(applicationContext) {
            Task { @MainActor [weak self] in self?.lastError = "两端数据版本不兼容，请将手机和手表应用一起更新" }
            return
        }
        guard let status = TransferProtocol.parseStatus(applicationContext) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if try self.evidence.save(status) {
                    let previous = self.lastWatchStatus
                    self.lastWatchStatus = status
                    await self.notifyCaptureProblem(status, previous: previous)
                }
            } catch { self.lastError = "手表状态无法保存：\(error.localizedDescription)" }
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.refreshDeviceStatus() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if TransferProtocol.hasUnsupportedVersion(userInfo) {
            Task { @MainActor [weak self] in self?.lastError = "两端数据版本不兼容，请将手机和手表应用一起更新" }
            return
        }
        guard let manifest = TransferProtocol.parseManifest(userInfo) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.ledger.merge(manifest)
                self.acknowledgeManifests(only: manifest.id)
            } catch {
                self.lastError = "场次清单保存失败：\(error.localizedDescription)"
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = error == nil && activationState == .activated
        Task { @MainActor [weak self] in
            self?.isActivated = activated
            self?.activationFailed = !activated
            self?.connectionText = activated ? "手表连接已启用" : "手表连接启用失败"
            if activated {
                self?.refreshDeviceStatus()
                self?.acknowledgeManifests()
                await self?.drainInbox()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isActivated = false
            self?.connectionText = "手表连接暂时不可用"
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isActivated = false
            self?.connectionText = "正在重新连接手表…"
        }
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if TransferProtocol.isKind(TransferProtocol.diagnosticsFileKind, file.metadata ?? [:]) {
            do {
                let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                try evidence.acceptDiagnostics(Data(contentsOf: file.fileURL))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.watchDiagnosticsDate = self.evidence.diagnostics()?.generatedAt
                    self.diagnosticsMessage = "已收到手表诊断，可重新生成包含两端记录的报告"
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in self?.diagnosticsMessage = "手表诊断接收失败，可重新请求：\(message)" }
            }
            return
        }
        if TransferProtocol.hasUnsupportedVersion(file.metadata ?? [:]) {
            Task { @MainActor [weak self] in self?.lastError = "录音数据版本不兼容，请更新手机和手表应用后重试" }
            return
        }
        guard let chunk = TransferProtocol.chunk(from: file.metadata ?? [:]) else { return }

        // WatchConnectivity deletes its URL after this callback returns, so
        // both metadata intent and a uniquely named copy are persisted here.
        do {
            _ = try inbox.stage(fileURL: file.fileURL, chunk: chunk)

            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.drainInbox()
            }
        } catch {
            let reason = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.lastEvent = "无法暂存手表文件"
                self?.lastError = reason
                _ = self?.sendAcknowledgement(
                    for: chunk,
                    accepted: false,
                    reason: reason
                )
            }
        }
    }
}
