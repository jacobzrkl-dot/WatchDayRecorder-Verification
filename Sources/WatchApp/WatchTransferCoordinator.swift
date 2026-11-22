import Combine
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
final class WatchTransferCoordinator: NSObject, ObservableObject {
    @Published private(set) var activationState = "正在连接手机…"
    @Published private(set) var lastEvent = "尚未传输"
    @Published private(set) var pendingManifestCount = 0

    private let store: ChunkQueueStore
    private let ledger: RecordingSessionLedger
    private var acknowledgedManifests: [UUID: Int] = [:]
    private let session: WCSession?
    private var retryTimer: Timer?
    var statusProvider: (() -> WatchCaptureStatus?)?
    private var lastPublishedStatus: WatchCaptureStatus?
    private nonisolated let delegateWork = DelegateWorkCounter()

    init(store: ChunkQueueStore, ledger: RecordingSessionLedger) {
        self.store = store
        self.ledger = ledger
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.scheduleEligibleTransfers() }
        }
    }

    deinit {
        retryTimer?.invalidate()
    }

    func enqueue(_ chunk: RecordingChunk) {
        lastEvent = "第 \(chunk.sequence + 1) 段已排队"
        scheduleEligibleTransfers()
    }

    func publishStatus(force: Bool = false) {
        guard let session, session.activationState == .activated, let status = statusProvider?() else { return }
        guard status.needsPublication(after: lastPublishedStatus, force: force) else { return }
        do {
            try session.updateApplicationContext(TransferProtocol.statusPayload(status))
            lastPublishedStatus = status
        } catch { lastEvent = "状态更新失败，录音仍保留：\(error.localizedDescription)" }
    }

    private func sendDiagnostics() {
        guard let session, session.activationState == .activated,
              !session.outstandingFileTransfers.contains(where: { TransferProtocol.isKind(TransferProtocol.diagnosticsFileKind, $0.file.metadata ?? [:]) }) else { return }
        do {
            let status = statusProvider?()
            let url = try DiagnosticJournal.shared.export(context: ["scope": "Watch local events",
                "pendingChunks": String(store.chunks.count), "mode": status?.mode.rawValue ?? "unknown"])
            session.transferFile(url, metadata: TransferProtocol.request(TransferProtocol.diagnosticsFileKind))
            lastEvent = "手表诊断已排队发送"
        } catch { lastEvent = "无法生成手表诊断：\(error.localizedDescription)" }
    }

    func handleBackgroundWake() async {
        guard let session else { return }
        if session.activationState != .activated { session.activate() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var drainedSince: ContinuousClock.Instant?
        while !Task.isCancelled, clock.now < deadline {
            await Task.yield()
            if session.activationState == .activated,
               ConnectivityDrainPolicy.canComplete(
                    activated: true, hasContentPending: session.hasContentPending,
                    pendingCallbacks: delegateWork.pending
               ) {
                // WatchKit invokes the background handler before delivering
                // delegate callbacks. Require a short stable drain window,
                // including callbacks waiting to hop to the main actor.
                if drainedSince == nil { drainedSince = clock.now }
                if let drainedSince, clock.now - drainedSince >= .milliseconds(500) {
                    scheduleEligibleTransfers()
                    return
                }
            } else {
                drainedSince = nil
            }
            do { try await Task<Never, Never>.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
    }

    private nonisolated func enqueueDelegateWork(
        _ body: @escaping @MainActor @Sendable (WatchTransferCoordinator) -> Void
    ) {
        let counter = delegateWork
        counter.begin()
        Task { @MainActor [weak self] in
            defer { counter.end() }
            guard let self else { return }
            body(self)
        }
    }

    func scheduleEligibleTransfers(forceRetry: Bool = false) {
        pendingManifestCount = ledger.manifests.filter { acknowledgedManifests[$0.id] != $0.revision }.count
        guard let session, session.activationState == .activated else { return }
        publishStatus()
        guard session.isCompanionAppInstalled else {
            activationState = "手机端未安装"
            lastEvent = "录音保留在手表，等待手机端"
            return
        }
        activationState = "手机连接已启用"
        scheduleManifests(using: session)
        let outstandingIDs = Set(session.outstandingFileTransfers.compactMap {
            $0.file.metadata?[TransferProtocol.Key.chunkID] as? String
        })
        let now = Date()
        let candidates = store.chunks.filter { chunk in
            guard ledger.manifests.first(where: { $0.id == chunk.sessionID })?.chunks
                .contains(SessionChunkReference(chunk)) == true else { return false }
            guard !outstandingIDs.contains(chunk.id.uuidString) else { return false }
            if forceRetry { return true }
            switch chunk.state {
            case .ready:
                return true
            case .queued, .failed:
                let exponent = min(chunk.attemptCount, 5)
                let delay = min(15 * 60, 30 * pow(2, Double(exponent)))
                return chunk.lastAttemptAt.map { now.timeIntervalSince($0) > delay } ?? true
            case .awaitingAcknowledgement:
                return chunk.lastAttemptAt.map { now.timeIntervalSince($0) > 15 * 60 } ?? true
            }
        }

        for chunk in candidates.prefix(3) {
            let fileURL = store.fileURL(for: chunk)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                store.markFailed(chunk.id, reason: "本地文件不存在")
                continue
            }
            session.transferFile(fileURL, metadata: TransferProtocol.metadata(for: chunk))
            store.markQueued(chunk.id)
            lastEvent = "正在发送第 \(chunk.sequence + 1) 段"
        }
    }

    private func scheduleManifests(using session: WCSession) {
        let outstanding = Set(session.outstandingUserInfoTransfers.compactMap {
            TransferProtocol.parseManifest($0.userInfo).map { "\($0.id):\($0.revision)" }
        })
        for manifest in ledger.manifests.filter({
            acknowledgedManifests[$0.id] != $0.revision
                && !outstanding.contains("\($0.id):\($0.revision)")
        }).prefix(3) {
            do {
                session.transferUserInfo(try TransferProtocol.manifestPayload(manifest))
            } catch {
                lastEvent = "场次清单发送失败：\(error.localizedDescription)"
            }
        }
    }

    private func handleAcknowledgement(_ ack: ChunkAcknowledgement) {
        if ack.accepted {
            do {
                try store.removeAfterAcknowledgement(id: ack.chunkID, sha256: ack.sha256)
                lastEvent = "手机已安全接收一段"
            } catch {
                store.markFailed(ack.chunkID, reason: error.localizedDescription)
                if let queueError = error as? QueueError, case .acknowledgementMismatch = queueError {
                    lastEvent = "确认内容不匹配，已保留手表原件"
                } else {
                    lastEvent = "手机已确认；手表清理未完成，请重试或恢复保留文件"
                }
            }
        } else {
            store.markFailed(ack.chunkID, reason: ack.reason ?? "手机拒绝文件")
            lastEvent = "手机请求重传"
        }
        scheduleEligibleTransfers()
    }
}

extension WatchTransferCoordinator: WCSessionDelegate {
    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        enqueueDelegateWork { coordinator in
            coordinator.scheduleEligibleTransfers()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = error == nil && activationState == .activated
        enqueueDelegateWork { coordinator in
            coordinator.activationState = activated ? "手机连接已启用" : "连接失败"
            coordinator.scheduleEligibleTransfers()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        if TransferProtocol.isKind(TransferProtocol.diagnosticsFileKind, fileTransfer.file.metadata ?? [:]) {
            let url = fileTransfer.file.fileURL
            enqueueDelegateWork { _ in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderDiagnostics").standardizedFileURL
                if url.deletingLastPathComponent().standardizedFileURL == root,
                   url.lastPathComponent.hasPrefix("WatchDayRecorder-diagnostics_") { try? FileManager.default.removeItem(at: url) }
            }
            return
        }
        let idString = fileTransfer.file.metadata?[TransferProtocol.Key.chunkID] as? String
        let errorDescription = error?.localizedDescription
        enqueueDelegateWork { coordinator in
            guard let idString, let id = UUID(uuidString: idString) else { return }
            if let errorDescription {
                coordinator.store.markFailed(id, reason: errorDescription)
                coordinator.lastEvent = "发送失败，稍后重试"
            } else {
                coordinator.store.markAwaitingAcknowledgement(id)
                coordinator.lastEvent = "已送达，等待手机校验"
            }
            coordinator.scheduleEligibleTransfers()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let acknowledgement = TransferProtocol.parseAcknowledgement(message) else { return }
        enqueueDelegateWork { coordinator in
            coordinator.handleAcknowledgement(acknowledgement)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if TransferProtocol.hasUnsupportedVersion(userInfo) {
            enqueueDelegateWork { $0.lastEvent = "两端数据版本不兼容，请将手机和手表应用一起更新" }
            return
        }
        if TransferProtocol.isKind(TransferProtocol.diagnosticsRequestKind, userInfo) {
            enqueueDelegateWork { $0.sendDiagnostics() }
            return
        }
        if TransferProtocol.isKind(TransferProtocol.statusRequestKind, userInfo) {
            enqueueDelegateWork { $0.publishStatus(force: true) }
            return
        }
        if let acknowledgement = TransferProtocol.parseManifestAcknowledgement(userInfo) {
            let id = acknowledgement.id
            let revision = acknowledgement.revision
            enqueueDelegateWork { coordinator in
                if coordinator.ledger.manifests.first(where: { $0.id == id })?.revision == revision {
                    coordinator.acknowledgedManifests[id] = revision
                }
                coordinator.scheduleEligibleTransfers()
            }
            return
        }
        if TransferProtocol.isRetryRequest(userInfo) {
            enqueueDelegateWork { coordinator in
                coordinator.scheduleEligibleTransfers(forceRetry: true)
            }
            return
        }
        guard let acknowledgement = TransferProtocol.parseAcknowledgement(userInfo) else { return }
        enqueueDelegateWork { coordinator in
            coordinator.handleAcknowledgement(acknowledgement)
        }
    }
}
