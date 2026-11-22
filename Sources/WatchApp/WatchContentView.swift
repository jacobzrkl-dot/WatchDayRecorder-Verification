import Foundation
import SwiftUI
import WatchKit

private enum WatchRecorderTheme {
    static let canvas = Color(red: 0.018, green: 0.022, blue: 0.035)
    static let red = Color(red: 1.00, green: 0.18, blue: 0.27)
    static let coral = Color(red: 1.00, green: 0.45, blue: 0.28)
    static let mint = Color(red: 0.24, green: 0.92, blue: 0.67)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.25)
}

struct WatchContentView: View {
    @ObservedObject var recorder: ChunkedRecorder
    @ObservedObject var store: ChunkQueueStore
    @ObservedObject var transfer: WatchTransferCoordinator
    @ObservedObject var ledger: RecordingSessionLedger
    @ObservedObject var recovery: WatchRecoveryController
    @State private var showSyncDetails = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 220

            ZStack {
                premiumBackground

                VStack(spacing: compact ? 5 : 8) {
                    Button { showSyncDetails = true } label: { statusCapsule }
                        .buttonStyle(.plain)
                        .accessibilityHint("打开同步详情与重试")
                    Spacer(minLength: compact ? 1 : 4)
                    recordControl(size: compact ? 78 : 94)
                    timeBlock(compact: compact)
                    Spacer(minLength: compact ? 1 : 3)
                    transferFooter(compact: compact)
                }
                .padding(.horizontal, compact ? 7 : 9)
                .padding(.vertical, compact ? 3 : 6)
            }
        }
        .animation(.snappy(duration: 0.28), value: recorder.isRecording)
        .animation(.snappy(duration: 0.28), value: recorder.isFinalizing)
        .animation(.snappy(duration: 0.28), value: recorder.isWaitingForResume)
        .sheet(isPresented: $showSyncDetails) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("同步详情").font(.headline)
                    Text(transfer.activationState).font(.caption)
                    Text(transfer.lastEvent).font(.caption2)
                    if let error = store.persistenceError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    if let error = ledger.lastError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    Button("重试待同步录音") {
                        transfer.scheduleEligibleTransfers(forceRetry: true)
                    }
                    if store.chunks.isEmpty {
                        Text("暂无待同步分段").font(.caption2)
                    }
                    ForEach(store.chunks) { chunk in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("第 \(chunk.sequence + 1) 段 · \(chunk.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2.weight(.semibold))
                            Text(transferStateText(chunk.state)).font(.caption2)
                            if let error = chunk.lastError {
                                Text(error).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                    if store.recoveryFileCount > 0 {
                        Text("另有 \(store.recoveryFileCount) 个待恢复文件。请先结束录音，再执行下方恢复。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Button(recovery.isRecovering ? "正在恢复…" : "检查并恢复中断录音") {
                        Task { await recovery.recover() }
                    }
                    .disabled(recorder.isSessionActive || recorder.isFinalizing || recovery.isRecovering)
                    Text(recovery.statusText).font(.caption2)
                    ForEach(Array(recovery.failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure).font(.caption2).foregroundStyle(.orange)
                    }
                    Button("返回录音") { showSyncDetails = false }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var premiumBackground: some View {
        ZStack {
            WatchRecorderTheme.canvas
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    (recorder.isSessionActive
                        ? WatchRecorderTheme.red
                        : WatchRecorderTheme.coral).opacity(0.24),
                    .clear
                ],
                center: .top,
                startRadius: 2,
                endRadius: 170
            )
            .ignoresSafeArea()

            Circle()
                .fill(WatchRecorderTheme.red.opacity(0.09))
                .frame(width: 130, height: 130)
                .blur(radius: 34)
                .offset(x: 72, y: 95)
                .accessibilityHidden(true)
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.85), radius: 4)

            Text(statusTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.7)
                .lineLimit(1)

            Spacer(minLength: 2)

            if totalPending > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up")
                    Text("\(totalPending)")
                        .monospacedDigit()
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(WatchRecorderTheme.amber)
            } else {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WatchRecorderTheme.mint)
            }
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.065), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle)，待同步 \(totalPending) 段")
    }

    private func recordControl(size: CGFloat) -> some View {
        Button(action: primaryAction) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.075), lineWidth: 7)

                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(
                        ringGradient,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.9), value: ringProgress)

                Circle()
                    .fill(controlGlow)
                    .padding(9)
                    .blur(radius: 7)

                Circle()
                    .fill(controlGradient)
                    .padding(13)
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.20), lineWidth: 0.8)
                            .padding(13)
                    }

                controlIcon
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .shadow(color: statusColor.opacity(recorder.isSessionActive ? 0.32 : 0.16), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(recorder.isFinalizing || recorder.isRecovering)
        .accessibilityLabel(recordButtonLabel)
        .accessibilityHint("录音每十分钟自动封存并同步到手机")
    }

    @ViewBuilder
    private var controlIcon: some View {
        if recorder.isFinalizing || recorder.isRecovering {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
        } else if recorder.isWaitingForResume {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
        } else if recorder.isSessionActive {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white)
                .frame(width: 25, height: 25)
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func timeBlock(compact: Bool) -> some View {
        VStack(spacing: compact ? 1 : 3) {
            Text(durationText(recorder.totalSessionElapsed))
                .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            Text(timeSubtitle)
                .font(.system(size: compact ? 9 : 10, weight: .medium, design: .rounded))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func transferFooter(compact: Bool) -> some View {
        VStack(spacing: compact ? 2 : 4) {
            HStack(spacing: 5) {
                Image(systemName: totalPending == 0 ? "iphone.radiowaves.left.and.right" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(totalPending == 0 ? WatchRecorderTheme.mint : WatchRecorderTheme.amber)
                Text(transferSummary)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            if store.recoveryFileCount > 0 {
                Label("\(store.recoveryFileCount) 个文件待恢复", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchRecorderTheme.amber)
            }

            if store.persistenceError != nil {
                Label("队列保存异常", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WatchRecorderTheme.amber)
            }

            if recorder.isWaitingForResume {
                Button("结束本次录音", role: .destructive) {
                    recorder.stopDaySession()
                }
                .font(.system(size: 9, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.92))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryAction() {
        guard !recorder.isRecovering else { return }
        if recorder.isFinalizing {
            return
        }
        if recorder.isWaitingForResume {
            recorder.resumeAfterInterruption()
        } else if recorder.isSessionActive {
            recorder.stopDaySession()
        } else {
            recorder.startDaySession()
        }
    }

    private func transferStateText(_ state: ChunkTransferState) -> String {
        switch state {
        case .ready: "等待传输"
        case .queued: "系统传输队列中"
        case .awaitingAcknowledgement: "等待手机校验确认"
        case .failed: "传输失败，可重试"
        }
    }

    private var totalPending: Int {
        store.pendingCount + store.awaitingAcknowledgementCount
    }

    private var ringProgress: Double {
        if recorder.isFinalizing { return 1 }
        if recorder.isWaitingForResume { return 0.72 }
        if recorder.isSessionActive {
            return min(1, max(0.02, recorder.elapsed / ChunkedRecorder.defaultChunkDuration))
        }
        return 0.10
    }

    private var statusColor: Color {
        if recorder.isFinalizing || recorder.isWaitingForResume || recorder.isRecovering {
            return WatchRecorderTheme.amber
        }
        if recorder.isRecording { return WatchRecorderTheme.red }
        if recorder.lastError != nil || ledger.lastError != nil || store.persistenceError != nil || store.recoveryFileCount > 0 {
            return WatchRecorderTheme.amber
        }
        return totalPending == 0 && transfer.pendingManifestCount == 0 ? WatchRecorderTheme.mint : WatchRecorderTheme.amber
    }

    private var statusTitle: String {
        if recorder.isRecovering { return "RECOVERING" }
        if recorder.isFinalizing { return "SECURING" }
        if recorder.isWaitingForResume { return "PAUSED" }
        if recorder.isRecording { return "RECORDING" }
        if recorder.lastError != nil || ledger.lastError != nil || store.persistenceError != nil || store.recoveryFileCount > 0 {
            return "ATTENTION"
        }
        if totalPending == 0 && transfer.pendingManifestCount > 0 { return "CONFIRMING" }
        return totalPending == 0 ? "READY" : "SYNCING"
    }

    private var timeSubtitle: String {
        if recorder.isRecovering { return "正在检查遗留录音，请稍候" }
        if let error = recorder.lastError { return error }
        if recorder.isFinalizing { return "正在安全封存当前分段" }
        if recorder.isWaitingForResume { return "点按主按钮继续录音" }
        if recorder.isSessionActive { return "第 \(recorder.currentSequence + 1) 段 · 10分钟自动保存" }
        return "一键开始 · 无需 iCloud"
    }

    private var subtitleColor: Color {
        recorder.isFinalizing || recorder.isWaitingForResume
            ? WatchRecorderTheme.amber
            : .white.opacity(0.46)
    }

    private var transferSummary: String {
        if store.persistenceError != nil { return "录音队列需要检查" }
        if store.recoveryFileCount > 0 { return "发现待恢复录音文件" }
        if totalPending == 0 && transfer.pendingManifestCount > 0 { return "等待手机确认场次清单" }
        if totalPending == 0 { return "暂无待同步分段" }
        return "\(totalPending) 段等待传到手机"
    }

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: recorder.isFinalizing || recorder.isWaitingForResume
                ? [WatchRecorderTheme.amber, WatchRecorderTheme.coral]
                : [WatchRecorderTheme.red, WatchRecorderTheme.coral, WatchRecorderTheme.red],
            center: .center
        )
    }

    private var controlGradient: LinearGradient {
        let colors: [Color]
        if recorder.isFinalizing || recorder.isWaitingForResume {
            colors = [WatchRecorderTheme.amber, WatchRecorderTheme.coral]
        } else {
            colors = [WatchRecorderTheme.red, Color(red: 0.72, green: 0.02, blue: 0.10)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var controlGlow: Color {
        recorder.isFinalizing || recorder.isWaitingForResume
            ? WatchRecorderTheme.amber.opacity(0.32)
            : WatchRecorderTheme.red.opacity(0.34)
    }

    private var recordButtonLabel: String {
        if recorder.isRecovering { return "正在恢复录音，完成后可开始新录音" }
        if recorder.isFinalizing { return "正在保存录音" }
        if recorder.isWaitingForResume { return "继续录音" }
        return recorder.isSessionActive ? "停止并保存录音" : "开始全天录音"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return String(
            format: "%02d:%02d:%02d",
            value / 3600,
            (value / 60) % 60,
            value % 60
        )
    }
}
