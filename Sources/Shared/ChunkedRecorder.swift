import AVFoundation
import Combine
import Foundation

@MainActor
final class ChunkedRecorder: NSObject, ObservableObject {
    nonisolated static let defaultChunkDuration: TimeInterval = 10 * 60

    @Published private(set) var isSessionActive = false
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var totalSessionElapsed: TimeInterval = 0
    @Published private(set) var currentSequence = 0
    @Published private(set) var statusText = "准备就绪"
    @Published private(set) var lastError: String?
    @Published private(set) var isWaitingForResume = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var isRecovering = false

    var onChunkFinalized: ((RecordingChunk) -> Void)?
    var onSessionUpdated: (() -> Void)?
    var onStateUpdated: (() -> Void)?

    func companionStatus(pendingChunks: Int) -> WatchCaptureStatus {
        let mode: WatchCaptureStatus.Mode
        if isRecording { mode = .recording }
        else if lastError != nil { mode = .error }
        else if isFinalizing { mode = .saving }
        else if isSessionActive { mode = .paused }
        else { mode = .stopped }
        return WatchCaptureStatus(timestamp: Date(), mode: mode, pendingChunks: pendingChunks,
            battery: environment.batteryLevel(), error: lastError.map { String($0.prefix(2000)) })
    }

    private let store: ChunkQueueStore
    private let ledger: RecordingSessionLedger
    private let chunkDuration: TimeInterval
    private let audioSession = AVAudioSession.sharedInstance()
    private var audioRecorder: (any RecordingDevice)?
    private let environment: RecorderEnvironment
    private var rotationTimer: Timer?
    private var elapsedTimer: Timer?
    private var activeChunk: ActiveChunk?
    private var capturedStopDuration: TimeInterval?
    private var sessionID: UUID?
    private var sessionStartedAt: Date?
    private var continueAfterFinalization = false
    private var interruptedSessionShouldResume = false
    private var resumeAfterFinalization: Bool?
    private var resumeRetryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var mediaServiceObservers: [NSObjectProtocol] = []
    private var healthMonitor = RecorderHealthMonitor()
    private var lastSafetyCheckUptime: TimeInterval = 0
    private var finalizationTimeoutTask: Task<Void, Never>?
    private var sessionHadInterruption = false

    init(
        store: ChunkQueueStore,
        ledger: RecordingSessionLedger,
        chunkDuration: TimeInterval = ChunkedRecorder.defaultChunkDuration,
        environment: RecorderEnvironment? = nil
    ) {
        self.store = store
        self.ledger = ledger
        self.chunkDuration = chunkDuration
        self.environment = environment ?? .live()
        super.init()
        configureAudioSession()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(
                    typeRawValue: rawType,
                    optionsRawValue: rawOptions
                )
            }
        }
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            mediaServiceObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleMediaServicesUnavailable() }
            })
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        for observer in mediaServiceObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func startDaySession() {
        guard
            !isSessionActive,
            !isRecovering,
            !isFinalizing,
            activeChunk == nil,
            audioRecorder == nil
        else { return }
        guard store.persistenceError == nil else {
            fail("录音队列异常，请先解锁并重启应用")
            return
        }
        lastError = nil

        guard hasSafeBatteryAndStorage() else { return }
        switch environment.authorization() {
        case .granted:
            beginNewSession()
        case .denied:
            fail("麦克风权限已关闭，请在设置中打开")
        case .undetermined:
            environment.requestAuthorization { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    granted ? self.beginNewSession() : self.fail("没有麦克风权限")
                }
            }
        }
    }

    func stopDaySession() {
        guard isSessionActive else { return }
        isSessionActive = false
        continueAfterFinalization = false
        interruptedSessionShouldResume = false
        resumeAfterFinalization = nil
        isWaitingForResume = false
        resumeRetryTask?.cancel()
        resumeRetryTask = nil
        statusText = "正在保存最后一段…"
        invalidateTimers()

        if let audioRecorder, activeChunk != nil {
            isFinalizing = true
            stopActiveRecorder(audioRecorder)
        } else {
            finishIdleSession()
        }
        onStateUpdated?()
    }

    private func beginNewSession() {
        guard
            !isSessionActive,
            !isRecovering,
            !isFinalizing,
            activeChunk == nil,
            audioRecorder == nil
        else { return }
        let newID = UUID()
        let startedAt = Date()
        do {
            try ledger.begin(id: newID, at: startedAt)
        } catch {
            fail("无法创建录音场次：\(error.localizedDescription)")
            return
        }
        sessionID = newID
        sessionStartedAt = startedAt
        sessionHadInterruption = false
        currentSequence = 0
        elapsed = 0
        totalSessionElapsed = 0
        isSessionActive = true
        isWaitingForResume = false
        isFinalizing = false
        onSessionUpdated?()
        if startNextChunk() { environment.feedback(.started) }
    }

    @discardableResult
    private func startNextChunk(endSessionOnFailure: Bool = true) -> Bool {
        guard isSessionActive, !isFinalizing, let sessionID else { return false }
        guard hasSafeBatteryAndStorage() else {
            stopDaySession()
            return false
        }

        let chunkID = UUID()
        let startedAt = Date()
        let url = store.partialURL(
            sessionID: sessionID,
            sequence: currentSequence,
            chunkID: chunkID
        )
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            try environment.configureSession()
            try environment.activateSession()
            let recorder = try environment.makeDevice(url, settings)
            recorder.onFinished = { [weak self] url, duration, success in
                self?.finalizeActiveChunk(recorderURL: url, recordedDuration: duration, successfully: success)
            }
            recorder.onError = { [weak self] url, duration, description in
                self?.handleEncodeError(recorderURL: url, recordedDuration: duration, errorDescription: description)
            }
            guard recorder.prepareToRecord() else { throw RecorderError.couldNotStart }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            guard recorder.record(forDuration: chunkDuration) else {
                throw RecorderError.couldNotStart
            }

            activeChunk = ActiveChunk(
                id: chunkID,
                sessionID: sessionID,
                sequence: currentSequence,
                startedAt: startedAt,
                partialURL: url
            )
            audioRecorder = recorder
            capturedStopDuration = nil
            healthMonitor = RecorderHealthMonitor()
            lastSafetyCheckUptime = ProcessInfo.processInfo.systemUptime
            // AVAudioRecorder owns the primary ten-minute stop. A Timer below
            // is only a watchdog because run-loop timers may be throttled in
            // the background.
            continueAfterFinalization = true
            isRecording = true
            isWaitingForResume = false
            isFinalizing = false
            lastError = nil
            statusText = "录音中 · 第 \(currentSequence + 1) 段"
            beginTimers()
            DiagnosticJournal.shared.record("recorder", "capture_started", details: ["sequence": String(currentSequence)])
            onStateUpdated?()
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            let message = "启动录音失败：\(error.localizedDescription)"
            if endSessionOnFailure {
                fail(message)
                isSessionActive = false
                isFinalizing = false
                finishIdleSession()
            } else {
                lastError = message
                statusText = "系统仍占用麦克风，正在重试"
                isRecording = false
                environment.deactivateSession()
            }
            return false
        }
    }

    private func rotateChunk() {
        guard isSessionActive, audioRecorder?.isRecording == true else { return }
        continueAfterFinalization = true
        isFinalizing = true
        statusText = "正在封存第 \(currentSequence + 1) 段…"
        invalidateTimers()
        if let audioRecorder { stopActiveRecorder(audioRecorder) }
    }

    private func stopActiveRecorder(_ recorder: any RecordingDevice) {
        let duration = recorder.currentTime
        if capturedStopDuration == nil, duration.isFinite, duration > 0 {
            capturedStopDuration = duration
        }
        isRecording = false
        if let context = activeChunk {
            finalizationTimeoutTask?.cancel()
            finalizationTimeoutTask = Task { @MainActor [weak self] in
                do { try await Task<Never, Never>.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
                guard let self, self.activeChunk?.id == context.id else { return }
                // A missing delegate callback must not leave Stop disabled forever.
                // Leave the original file for the explicit recovery workflow.
                self.audioRecorder?.onFinished = nil
                self.audioRecorder?.onError = nil
                self.isSessionActive = false
                self.continueAfterFinalization = false
                self.interruptedSessionShouldResume = false
                self.resumeAfterFinalization = nil
                self.finalizeActiveChunk(
                    recorderURL: context.partialURL, recordedDuration: duration,
                    successfully: false
                )
            }
        }
        recorder.stop()
    }

    private func finalizeActiveChunk(
        recorderURL: URL,
        recordedDuration: TimeInterval,
        successfully: Bool
    ) {
        guard let context = activeChunk else {
            return
        }
        guard context.partialURL.standardizedFileURL == recorderURL.standardizedFileURL else {
            return
        }
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        invalidateTimers()

        isFinalizing = true
        let wallClockDuration = Date().timeIntervalSince(context.startedAt)
        let measuredDuration: TimeInterval
        if let capturedStopDuration {
            measuredDuration = capturedStopDuration
        } else if recordedDuration.isFinite, recordedDuration > 0 {
            measuredDuration = recordedDuration
        } else {
            // Automatic record(forDuration:) completion can be delivered
            // late in the background, after currentTime has reset to zero.
            measuredDuration = min(chunkDuration, max(0, wallClockDuration))
        }
        capturedStopDuration = nil
        activeChunk = nil
        audioRecorder = nil
        isRecording = false

        // Resume capture before checksum, queue writes and transfer scheduling.
        // The finished file remains owned by its captured context, while every
        // callback from the new device is still checked against its own URL.
        let rollsOver = successfully && isSessionActive && continueAfterFinalization
            && !interruptedSessionShouldResume && resumeAfterFinalization == nil
        if rollsOver {
            currentSequence = context.sequence + 1
            isFinalizing = false
            continueAfterFinalization = false
            let restarted = startNextChunk(endSessionOnFailure: false)
            do {
                try persistFinishedChunk(context, duration: measuredDuration)
            } catch {
                fail("保存第 \(context.sequence + 1) 段失败：\(error.localizedDescription)")
                store.refreshRecoveryCount()
                // Stop the replacement device before ending the session. Its
                // completion/watchdog retains the new file for recovery too.
                if isSessionActive { stopDaySession() }
                else { finishIdleSession() }
                return
            }
            if !restarted, isSessionActive {
                sessionHadInterruption = true
                scheduleResumeRetries()
            }
            return
        }

        if successfully {
            do {
                try persistFinishedChunk(context, duration: measuredDuration)
                currentSequence += 1
            } catch {
                fail("保存第 \(context.sequence + 1) 段失败：\(error.localizedDescription)")
                store.refreshRecoveryCount()
                isSessionActive = false
                continueAfterFinalization = false
            }
        } else {
            fail("第 \(context.sequence + 1) 段没有正常封存，已保留恢复文件")
            store.refreshRecoveryCount()
            isSessionActive = false
            continueAfterFinalization = false
        }
        isFinalizing = false

        if let shouldResume = resumeAfterFinalization {
            resumeAfterFinalization = nil
            continueAfterFinalization = false
            if isSessionActive {
                shouldResume ? scheduleResumeRetries() : enterManualResumeState()
            } else {
                finishIdleSession()
            }
        } else if isSessionActive && continueAfterFinalization {
            continueAfterFinalization = false
            startNextChunk()
        } else if isSessionActive && interruptedSessionShouldResume {
            // An interruption end notification is not guaranteed. Once the
            // current file is safe, expose an explicit user-controlled retry.
            enterManualResumeState()
        } else if !isSessionActive || !interruptedSessionShouldResume {
            finishIdleSession()
        }
    }

    private func persistFinishedChunk(_ context: ActiveChunk, duration: TimeInterval) throws {
        let chunk = try store.finalize(
            partialURL: context.partialURL,
            chunkID: context.id,
            sessionID: context.sessionID,
            sequence: context.sequence,
            startedAt: context.startedAt,
            duration: duration
        )
        try ledger.register(chunk)
        DiagnosticJournal.shared.record("recorder", "chunk_committed", details: ["sequence": String(chunk.sequence), "bytes": String(chunk.byteCount)])
        onChunkFinalized?(chunk)
    }

    private func beginTimers() {
        invalidateTimers()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration + 2, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.rotateChunk() }
        }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeChunk != nil else { return }
                self.checkRecorderHealth()
                if let sessionStartedAt = self.sessionStartedAt {
                    self.totalSessionElapsed = Date().timeIntervalSince(sessionStartedAt)
                }
            }
        }
    }

    private func checkRecorderHealth() {
        guard isSessionActive, !isFinalizing, let recorder = audioRecorder else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let audioTime = recorder.currentTime
        if audioTime.isFinite, audioTime >= 0 { elapsed = audioTime }
        if healthMonitor.isStalled(
            isRecording: recorder.isRecording, audioTime: audioTime, uptime: uptime
        ) {
            fail("录音器已停止推进，正在保存；请检查后重新开始")
            stopDaySession()
            return
        }
        if uptime - lastSafetyCheckUptime >= 30 {
            lastSafetyCheckUptime = uptime
            if !hasSafeBatteryAndStorage() { stopDaySession() }
        }
    }

    func handleMediaServicesUnavailable() {
        guard isSessionActive || activeChunk != nil || isFinalizing else { return }
        resumeRetryTask?.cancel()
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        invalidateTimers()
        // Media service resets invalidate existing audio objects. Do not reuse
        // the recorder or delete its unfinalized file, or restart without a tap.
        audioRecorder?.onFinished = nil
        audioRecorder?.onError = nil
        audioRecorder = nil
        activeChunk = nil
        capturedStopDuration = nil
        isSessionActive = false
        isRecording = false
        isFinalizing = false
        continueAfterFinalization = false
        interruptedSessionShouldResume = false
        resumeAfterFinalization = nil
        fail("系统音频服务中断，录音已停止；请恢复文件后重新开始")
        store.refreshRecoveryCount()
        finishIdleSession()
    }

    private func invalidateTimers() {
        rotationTimer?.invalidate()
        elapsedTimer?.invalidate()
        rotationTimer = nil
        elapsedTimer = nil
    }

    private func finishIdleSession() {
        finalizationTimeoutTask?.cancel()
        finalizationTimeoutTask = nil
        resumeRetryTask?.cancel()
        resumeRetryTask = nil
        invalidateTimers()
        isRecording = false
        elapsed = 0
        if activeChunk == nil {
            isFinalizing = false
        }
        environment.deactivateSession()
        if !isSessionActive {
            let hadSession = sessionID != nil
            if let sessionID {
                do {
                    try ledger.end(id: sessionID, needsRecovery: lastError != nil, interrupted: sessionHadInterruption)
                    onSessionUpdated?()
                } catch {
                    lastError = "结束清单保存失败：\(error.localizedDescription)"
                }
            }
            isWaitingForResume = false
            statusText = lastError == nil ? "已停止，录音均已封存" : "已停止"
            if hadSession, lastError == nil { environment.feedback(.stopped) }
            sessionID = nil
            sessionStartedAt = nil
        }
        onStateUpdated?()
    }

    private func configureAudioSession() {
        do {
            try environment.configureSession()
        } catch {
            lastError = "音频会话配置失败：\(error.localizedDescription)"
        }
    }

    private func hasSafeBatteryAndStorage() -> Bool {
        let battery = environment.batteryLevel()
        if battery >= 0, battery <= 0.10 {
            fail("电量低于 10%，为避免丢失已停止")
            return false
        }

        do {
            let values = try FileManager.default.attributesOfFileSystem(forPath: store.recordingsDirectory.path)
            if let bytes = (values[.systemFreeSize] as? NSNumber)?.int64Value, bytes < 100 * 1024 * 1024 {
                fail("可用空间低于 100 MB")
                return false
            }
        } catch {
            // A failed capacity query must not discard an active recording.
        }
        return true
    }

    private func fail(_ message: String) {
        DiagnosticJournal.shared.record("recorder", "error", details: ["message": message])
        lastError = message
        statusText = message
        environment.feedback(.failure)
        onStateUpdated?()
    }

    func beginRecovery() -> Bool {
        guard !isSessionActive, !isFinalizing, !isRecovering, activeChunk == nil else { return false }
        isRecovering = true
        return true
    }

    func endRecovery() { isRecovering = false }

    func resumeAfterInterruption() {
        guard isSessionActive, !isRecording, !isFinalizing else { return }
        interruptedSessionShouldResume = false
        resumeAfterFinalization = nil
        scheduleResumeRetries()
    }

    private func scheduleResumeRetries() {
        resumeRetryTask?.cancel()
        isWaitingForResume = false
        statusText = "正在恢复录音…"
        resumeRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<5 {
                guard !Task.isCancelled, self.isSessionActive, !self.isRecording else { return }
                if attempt > 0 {
                    let seconds = UInt64(1 << min(attempt - 1, 4))
                    try? await Task<Never, Never>.sleep(
                        nanoseconds: seconds * 1_000_000_000
                    )
                    guard !Task.isCancelled else { return }
                }
                if self.startNextChunk(endSessionOnFailure: false) {
                    self.environment.feedback(.started)
                    self.resumeRetryTask = nil
                    return
                }
            }
            self.resumeRetryTask = nil
            self.enterManualResumeState()
        }
    }

    private func enterManualResumeState() {
        guard isSessionActive, !Task.isCancelled else { return }
        isWaitingForResume = true
        isRecording = false
        isFinalizing = false
        statusText = "录音已中断，点按尝试继续"
        environment.deactivateSession()
        onStateUpdated?()
    }

    func handleAudioInterruption(
        typeRawValue: UInt,
        optionsRawValue: UInt
    ) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else {
            return
        }

        switch type {
        case .began:
            guard isSessionActive else { return }
            DiagnosticJournal.shared.record("recorder", "interruption_began")
            sessionHadInterruption = true
            interruptedSessionShouldResume = true
            resumeAfterFinalization = nil
            resumeRetryTask?.cancel()
            resumeRetryTask = nil
            isWaitingForResume = false
            continueAfterFinalization = false
            statusText = "被系统打断，正在封存当前段"
            invalidateTimers()
            isFinalizing = activeChunk != nil
            if let audioRecorder {
                stopActiveRecorder(audioRecorder)
            } else if activeChunk == nil {
                enterManualResumeState()
            }
        case .ended:
            guard interruptedSessionShouldResume, isSessionActive else { return }
            interruptedSessionShouldResume = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            let shouldResume = options.contains(.shouldResume)
            if activeChunk == nil {
                shouldResume ? scheduleResumeRetries() : enterManualResumeState()
            } else {
                // The end notification can race the recorder delegate. Let the
                // in-flight finalization start the next file exactly once.
                resumeAfterFinalization = shouldResume
            }
        @unknown default:
            break
        }
    }

    private func handleEncodeError(
        recorderURL: URL,
        recordedDuration: TimeInterval,
        errorDescription: String?
    ) {
        guard activeChunk?.partialURL.standardizedFileURL == recorderURL.standardizedFileURL else {
            return
        }
        lastError = errorDescription ?? "录音编码失败"
        isSessionActive = false
        continueAfterFinalization = false
        finalizeActiveChunk(
            recorderURL: recorderURL,
            recordedDuration: recordedDuration,
            successfully: false
        )
    }
}

private struct ActiveChunk {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let startedAt: Date
    let partialURL: URL
}

private enum RecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? { "录音器没有启动" }
}
