import Foundation
import SwiftUI

private enum RecorderTheme {
    static let canvas = Color(red: 0.025, green: 0.03, blue: 0.045)
    static let elevated = Color.white.opacity(0.065)
    static let stroke = Color.white.opacity(0.10)
    static let primary = Color(red: 1.00, green: 0.22, blue: 0.30)
    static let secondary = Color(red: 1.00, green: 0.48, blue: 0.30)
    static let success = Color(red: 0.25, green: 0.91, blue: 0.66)
    static let warning = Color(red: 1.00, green: 0.73, blue: 0.28)
}

private enum SessionListFilter: String, CaseIterable {
    case active = "录音"
    case complete = "已收齐"
    case attention = "待处理"
    case archived = "已归档"
}

struct PhoneContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var library: PhoneRecordingLibrary
    @ObservedObject var receiver: PhoneConnectivityReceiver
    @ObservedObject var ledger: RecordingSessionLedger
    @ObservedObject var catalog: PhoneSessionCatalog
    @StateObject private var playback = AudioPlaybackController()
    @State private var showSyncDetails = false
    @State private var showStorage = false
    @State private var searchText = ""
    @State private var listFilter = SessionListFilter.active
    @AppStorage("hasSeenRecorderSetup") private var hasSeenSetup = false
    @State private var showSetup = false

    private var sessions: [PhoneRecordingSession] {
        PhoneRecordingSession.group(library.chunks, manifests: ledger.manifests, unavailableIDs: library.unavailableChunkIDs)
    }

    private var filteredSessions: [PhoneRecordingSession] {
        sessions.filter { session in
            let archived = catalog.isArchived(session.id)
            let matchesCategory: Bool
            switch listFilter {
            case .active: matchesCategory = !archived
            case .complete: matchesCategory = !archived && session.isComplete
            case .attention: matchesCategory = !archived && !session.isComplete
            case .archived: matchesCategory = archived
            }
            return matchesCategory && RecordingSearch.matches(
                query: searchText, title: catalog.title(for: session.id), date: session.startedAt
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                premiumBackground

                ScrollView {
                    LazyVStack(spacing: 16) {
                        pageHeader
                        heroCard
                        syncCard
                        listControls
                        sessionList
                        storageFooter
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                receiver.refreshDeviceStatus()
                library.refreshLocalAvailability()
                Task { await receiver.resumePendingImports() }
            }
        }
        .sheet(isPresented: $showStorage) { PhoneStorageView(library: library, receiver: receiver, ledger: ledger, catalog: catalog) }
        .sheet(isPresented: $showSetup) {
            PhoneSetupView(receiver: receiver) { hasSeenSetup = true }
        }
        .task { if !hasSeenSetup { showSetup = true } }
        .sheet(isPresented: $showSyncDetails) {
            NavigationStack {
                List {
                    Section("当前状态") {
                        Text(receiver.setupState.title)
                        Text(receiver.setupState.guidance)
                        Text(receiver.lastEvent)
                    }
                    Section("失败原因") {
                        Text(library.lastError ?? ledger.lastError ?? catalog.lastError ?? receiver.lastError ?? "暂未记录错误")
                            .textSelection(.enabled)
                    }
                    Section {
                        Button("重试接收并请求手表重传") {
                            Task { await receiver.retrySync() }
                        }
                        .disabled(receiver.isRetrying)
                        Text("手机只能请求手表重传仍保留的录音。传输时间由系统安排；可到手表同步详情查看各段状态。")
                            .font(.caption)
                    }
                }
                .navigationTitle("同步详情")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showSyncDetails = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var premiumBackground: some View {
        ZStack {
            RecorderTheme.canvas
                .ignoresSafeArea()

            RadialGradient(
                colors: [RecorderTheme.primary.opacity(0.22), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 340
            )
            .ignoresSafeArea()

            Circle()
                .fill(RecorderTheme.secondary.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -150, y: 300)
                .accessibilityHidden(true)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("WATCH ARCHIVE")
                    .font(.caption2.weight(.bold))
                    .tracking(2.2)
                    .foregroundStyle(RecorderTheme.primary)
                Text("全天录音")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
            }

            Spacer()
            connectionBadge
            Button { showStorage = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("存储与使用帮助")
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(syncColor)
                .frame(width: 7, height: 7)
                .shadow(color: syncColor.opacity(0.8), radius: 5)
            Text(connectionBadgeText)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(RecorderTheme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(receiver.connectionText)
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(library.unavailableChunkIDs.isEmpty ? "手机本地录音" : "录音记录 · 部分文件待检查")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(durationText(totalDuration, compact: true))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 12)

                ZStack {
                    Circle()
                        .fill(RecorderTheme.primary.opacity(0.16))
                    Circle()
                        .stroke(RecorderTheme.primary.opacity(0.32), lineWidth: 1)
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [RecorderTheme.primary, RecorderTheme.secondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 58, height: 58)
            }

            decorativeWaveform

            HStack(spacing: 0) {
                heroMetric(title: "录音场次", value: "\(sessions.count)")
                metricDivider
                heroMetric(title: "音频分段", value: "\(library.chunks.count)")
                metricDivider
                heroMetric(title: "本地占用", value: byteText(totalBytes))
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(RecorderTheme.elevated)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), RecorderTheme.primary.opacity(0.16), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: RecorderTheme.primary.opacity(0.12), radius: 30, y: 16)
    }

    private var decorativeWaveform: some View {
        let levels: [CGFloat] = [10, 18, 28, 15, 34, 22, 40, 26, 17, 32, 20, 12, 25, 36, 18, 27, 14, 22]
        return HStack(spacing: 4) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                RecorderTheme.primary.opacity(index.isMultiple(of: 3) ? 0.95 : 0.48),
                                RecorderTheme.secondary.opacity(0.34)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: level)
            }
        }
        .frame(height: 42)
        .accessibilityHidden(true)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 32)
    }

    private func heroMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    private var syncCard: some View {
        VStack(spacing: 12) {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(syncColor.opacity(0.12))
                Image(
                    systemName: library.lastError == nil && receiver.lastError == nil
                        ? "applewatch.radiowaves.left.and.right"
                        : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(syncColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(receiver.setupState.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(library.lastError ?? receiver.lastError ?? (receiver.setupState == .ready ? receiver.lastEvent : receiver.setupState.guidance))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(
                systemName: library.lastError == nil && receiver.lastError == nil && receiver.setupState == .ready
                    ? "checkmark.shield.fill"
                    : "exclamationmark.shield.fill"
            )
                .font(.title3)
                .foregroundStyle(syncColor.opacity(0.92))
        }
            HStack {
                Button("查看同步详情", systemImage: "info.circle") {
                    showSyncDetails = true
                }
                Spacer()
                Button {
                    Task { await receiver.retrySync() }
                } label: {
                    Label(receiver.isRetrying ? "正在处理" : "重试同步", systemImage: "arrow.clockwise")
                }
                .disabled(receiver.isRetrying)
            }
            .font(.caption.weight(.semibold))
            .tint(RecorderTheme.primary)
            if let status = receiver.lastWatchStatus {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(status.summary(at: context.date)).font(.caption)
                            .foregroundStyle(status.mode == .paused || status.mode == .error || context.date.timeIntervalSince(status.timestamp) > 180 ? Color.orange : Color.secondary)
                        Text("手表报告时间 \(status.timestamp.formatted(date: .abbreviated, time: .standard)) · 待确认 \(status.pendingChunks) 段")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("尚未收到手表采集状态；同步通道就绪不代表正在录音")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("请求最新手表状态") { receiver.requestWatchEvidence(diagnostics: false) }
                .font(.caption).tint(RecorderTheme.primary)
        }
        .padding(15)
        .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(RecorderTheme.stroke))
    }

    @ViewBuilder
    private var sessionList: some View {
        if sessions.isEmpty {
            emptyState
        } else if filteredSessions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title2)
                Text(listFilter == .archived && searchText.isEmpty ? "还没有归档录音" : "没有匹配的录音")
                    .font(.headline)
                Text("可以清空搜索词，或切换上方分类。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("录音记录")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("按开始时间自动归档")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.44))
                }
                Spacer()
                Text("\(filteredSessions.count) 场")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RecorderTheme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RecorderTheme.primary.opacity(0.10), in: Capsule())
            }
            .padding(.top, 6)

            ForEach(filteredSessions) { session in
                NavigationLink {
                    PhoneSessionDetailView(
                        initialSession: session,
                        library: library,
                        ledger: ledger,
                        catalog: catalog,
                        playback: playback
                    )
                } label: {
                    sessionCard(session)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var listControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称或日期（YYYY-MM-DD）", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("清空搜索")
                }
            }
            .padding(14)
            .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SessionListFilter.allCases, id: \.self) { filter in
                        Button { listFilter = filter } label: {
                            Text(filter.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .foregroundStyle(listFilter == filter ? .white : .white.opacity(0.55))
                                .background(listFilter == filter ? RecorderTheme.primary : RecorderTheme.elevated, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(listFilter == filter ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(RecorderTheme.primary.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(RecorderTheme.primary)
            }
            Text("等待第一段录音")
                .font(.headline)
                .foregroundStyle(.white)
            Text("在 Apple Watch 点按红色按钮。\n第一段安全封存后会自动出现在这里。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
            Button("查看安装与授权步骤") { showSetup = true }
                .font(.subheadline.weight(.semibold)).tint(RecorderTheme.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(RecorderTheme.stroke))
    }

    private func sessionCard(_ session: PhoneRecordingSession) -> some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(session.startedAt, format: .dateTime.day())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(session.startedAt, format: .dateTime.month(.abbreviated))
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(RecorderTheme.primary)
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 64)
            .background(
                RecorderTheme.primary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(catalog.title(for: session.id) ?? session.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    continuityBadge(session.isContinuous, hasChunks: !session.chunks.isEmpty)
                }

                HStack(spacing: 12) {
                    Label(durationText(session.duration, compact: true), systemImage: "clock")
                    Label("\(session.chunks.count) 段", systemImage: "square.stack.3d.up")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.48))

                Text(session.receiptTitle)
                    .font(.caption2)
                    .foregroundStyle(session.isComplete ? RecorderTheme.success : RecorderTheme.warning)
                    .lineLimit(2)
            }

            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.26))
        }
        .padding(14)
        .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(RecorderTheme.stroke))
    }

    private func continuityBadge(_ continuous: Bool, hasChunks: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: hasChunks ? (continuous ? "checkmark" : "exclamationmark") : "hourglass")
            Text(hasChunks ? (continuous ? "已收段连续" : "存在缺段") : "等待首段")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(continuous ? RecorderTheme.success : RecorderTheme.warning)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (continuous ? RecorderTheme.success : RecorderTheme.warning).opacity(0.10),
            in: Capsule()
        )
    }

    private var storageFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
            Text("本地保存 · 可在存储与帮助中查看位置")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.38))
        .padding(.vertical, 8)
    }

    private var totalDuration: TimeInterval {
        library.chunks.reduce(0) { $0 + $1.duration }
    }

    private var totalBytes: Int64 {
        library.chunks.reduce(0) { $0 + $1.byteCount }
    }

    private var syncColor: Color {
        library.lastError == nil && ledger.lastError == nil && catalog.lastError == nil && receiver.lastError == nil && receiver.setupState == .ready
            ? RecorderTheme.success
            : RecorderTheme.warning
    }

    private var connectionBadgeText: String {
        if library.lastError != nil || ledger.lastError != nil || catalog.lastError != nil || receiver.lastError != nil { return "需检查" }
        return receiver.setupState.badge
    }
}

private struct PhoneSessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let initialSession: PhoneRecordingSession
    @ObservedObject var library: PhoneRecordingLibrary
    @ObservedObject var ledger: RecordingSessionLedger
    @ObservedObject var catalog: PhoneSessionCatalog
    @ObservedObject var playback: AudioPlaybackController
    @StateObject private var exporter = PhoneSessionExporter()
    @State private var showRename = false
    @State private var draftTitle = ""
    @State private var showArchiveConfirmation = false
    @State private var managementError: String?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    private var selectedChunks: [PhoneRecordingChunk] {
        RecordingSessionPlan.selectedChunks(session.chunks, ids: selectedIDs, unavailable: library.unavailableChunkIDs)
    }

    private var session: PhoneRecordingSession {
        PhoneRecordingSession.group(library.chunks, manifests: ledger.manifests, unavailableIDs: library.unavailableChunkIDs)
            .first(where: { $0.id == initialSession.id }) ?? initialSession
    }

    private var detailCanvas: some View {
        ZStack {
            RecorderTheme.canvas.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 14) {
                    detailHero
                    sessionActions
                    selectionActions
                    gapSummary

                    if let error = playback.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(RecorderTheme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .background(
                                RecorderTheme.warning.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                    }

                    HStack {
                        Text("分段音频")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text("已收到 \(session.chunks.count) 段")
                            .font(.caption2)
                            .foregroundStyle(RecorderTheme.success)
                    }
                    .padding(.top, 4)

                    ForEach(session.chunks) { chunk in
                        chunkCard(chunk)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    var body: some View {
        detailCanvas
        .navigationTitle(catalog.title(for: session.id) ?? "录音详情")
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(RecorderTheme.canvas.opacity(0.92), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.white)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重命名", systemImage: "pencil") {
                        draftTitle = catalog.title(for: session.id) ?? ""
                        showRename = true
                    }
                    Button(catalog.isArchived(session.id) ? "恢复到录音列表" : "归档录音", systemImage: "archivebox") {
                        showArchiveConfirmation = true
                    }
                    .disabled(exporter.isPreparing || session.manifest.map { $0.endedAt == nil } == true)
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("录音管理")
            }
        }
        .alert("重命名录音", isPresented: $showRename) {
            TextField("填写 1 至 80 个字符", text: $draftTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                do { try catalog.rename(session.id, title: draftTitle) }
                catch { managementError = error.localizedDescription }
            }
        } message: {
            Text("只修改场次名称，不改变原始音频文件。")
        }
        .confirmationDialog(catalog.isArchived(session.id) ? "恢复这场录音？" : "归档这场录音？", isPresented: $showArchiveConfirmation, titleVisibility: .visible) {
            Button(catalog.isArchived(session.id) ? "恢复到录音列表" : "归档并保留文件") {
                do {
                    try catalog.setArchived(session.id, !catalog.isArchived(session.id))
                    if session.chunks.contains(where: { $0.id == playback.activeChunkID }) { playback.stop() }
                    dismiss()
                } catch { managementError = error.localizedDescription }
            }
        } message: {
            Text("归档只调整列表分类，不删除文件，也不会释放录音空间。可在首页“已归档”中恢复。")
        }
        .alert("操作未完成", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("好") { managementError = nil }
        } message: { Text(managementError ?? "") }
        .onChange(of: session.chunks) { _, chunks in
            selectedIDs.formIntersection(Set(chunks.map(\.id)))
            exporter.invalidate()
        }
        .onChange(of: selectedChunks) { _, _ in exporter.invalidate() }
        .onChange(of: session.manifest) { _, _ in exporter.invalidate() }
        .onChange(of: catalog.title(for: session.id)) { _, _ in exporter.invalidate() }
        .onDisappear { exporter.cancel() }
    }

    private var sessionActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.receiptTitle)
                .font(.caption)
                .foregroundStyle(session.isComplete ? RecorderTheme.success : RecorderTheme.warning)
            if !session.isComplete {
                Text("尚未确认整场收齐。可先试听、导出当前已收到的分段，也可返回首页重试同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.manifest?.wasInterrupted == true {
                Text("这场录音曾被中断，音频可能存在时间空档。")
                    .font(.caption).foregroundStyle(RecorderTheme.warning)
            }
            HStack(spacing: 16) {
                Button {
                    playback.toggleSession(chunks: session.chunks, directory: library.recordingsDirectory)
                } label: {
                    Label(
                        playback.isPlayingPlaylist(session.chunks) ? "暂停连播" : "连续播放",
                        systemImage: playback.isPlayingPlaylist(session.chunks) ? "pause.fill" : "play.fill"
                    )
                }
                .disabled(!session.isContinuous)
                Spacer()
                if exporter.isPreparing {
                    Button("取消导出") { exporter.cancel() }
                } else {
                    Button {
                        Task {
                            await exporter.prepare(chunks: session.chunks, directory: library.recordingsDirectory, displayName: catalog.title(for: session.id))
                        }
                    } label: {
                        Label(session.isComplete ? "整场合并导出" : "导出已收分段", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!session.isContinuous)
                }
            }
            .font(.subheadline.weight(.semibold))
            .tint(RecorderTheme.primary)
            if !session.isContinuous {
                Text("分段有缺失：请返回首页重试同步，或先逐段播放、导出。")
                    .font(.caption)
                    .foregroundStyle(RecorderTheme.warning)
            }
            if session.chunks.contains(where: { $0.id == playback.activeChunkID }) {
                if let message = playback.resumeMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                Button("回到开头") { playback.seek(to: 0) }.font(.caption)
                if let current = session.chunks.first(where: { $0.id == playback.activeChunkID }) {
                    Text("第 \(current.sequence + 1) 段 · \(playback.playlistSessionID == session.id ? "按已收分段连播" : "单段播放")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { playback.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
                    Slider(value: Binding(get: { playback.progress }, set: { playback.seek(to: $0) }), in: 0...1,
                        onEditingChanged: { editing in if !editing { playback.finishSeeking() } })
                    Button { playback.skip(seconds: 15) } label: { Image(systemName: "goforward.15") }
                    Button { playback.stop() } label: { Image(systemName: "stop.fill") }
                }
                .tint(RecorderTheme.primary)
                .accessibilityLabel("当前分段播放进度")
                HStack {
                    Text("\(durationText(playback.currentTime, compact: false)) / \(durationText(playback.duration, compact: false))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button(String(format: "%.2g×", rate)) { playback.setPlaybackRate(rate) }
                        }
                    } label: {
                        Text(String(format: "%.2g× 倍速", playback.playbackRate)).font(.caption.weight(.semibold))
                    }
                }
            }
            if exporter.isPreparing {
                ProgressView(value: exporter.progress).tint(RecorderTheme.primary)
                Text("\(Int(exporter.progress * 100))% · 预留空间约 \(ByteCountFormatter.string(fromByteCount: exporter.requiredSpaceBytes, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !exporter.statusText.isEmpty {
                Text(exporter.statusText).font(.caption).foregroundStyle(.secondary)
            }
            if let error = exporter.errorMessage {
                Text(error).font(.caption).foregroundStyle(RecorderTheme.warning)
            }
            if let url = exporter.exportedURL {
                ShareLink(item: url) {
                    Label("保存合并音频到文件 / 分享", systemImage: "square.and.arrow.up")
                }
                .font(.subheadline.weight(.semibold))
                .tint(RecorderTheme.success)
            }
        }
        .padding(16)
        .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 20))
    }

    private var detailHero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = catalog.title(for: session.id) {
                        Text(title).font(.headline).foregroundStyle(.white).lineLimit(2)
                    }
                    Text(session.startedAt, format: .dateTime.year().month().day())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RecorderTheme.primary)
                    Text(session.startedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(RecorderTheme.primary)
            }

            HStack(spacing: 16) {
                detailMetric("时长", durationText(session.duration, compact: true))
                detailMetric("分段", "\(session.chunks.count)")
                detailMetric("大小", byteText(session.byteCount))
            }
        }
        .padding(20)
        .background {
            LinearGradient(
                colors: [RecorderTheme.primary.opacity(0.20), RecorderTheme.elevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(RecorderTheme.stroke))
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectionActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(isSelecting ? "退出分段选择" : "选择部分分段") {
                    isSelecting.toggle(); selectedIDs = []; exporter.invalidate()
                }.disabled(exporter.isPreparing)
                Spacer()
                if isSelecting {
                    Button("全选可用分段") { selectedIDs = Set(session.chunks.filter { !library.unavailableChunkIDs.contains($0.id) }.map(\.id)) }
                        .disabled(exporter.isPreparing)
                }
            }
            if isSelecting {
                Text("已选 \(selectedChunks.count) 段 · \(durationText(selectedChunks.reduce(0) { $0 + $1.duration }, compact: false))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(playback.isPlayingPlaylist(selectedChunks) ? "暂停所选" : "播放所选") { playback.toggleSession(chunks: selectedChunks, directory: library.recordingsDirectory, allowGaps: true) }
                    Spacer()
                    Button("导出所选") {
                        let chunks = selectedChunks
                        Task { await exporter.prepare(chunks: chunks, directory: library.recordingsDirectory,
                            displayName: (catalog.title(for: session.id) ?? "录音") + "_所选片段", allowGaps: true) }
                    }
                }.disabled(selectedChunks.isEmpty || exporter.isPreparing)
                Text("只拼接所选音频，不补入缺段或时间空档，也不改变整场收齐状态。")
                    .font(.caption2).foregroundStyle(RecorderTheme.warning)
            }
        }.font(.subheadline).tint(RecorderTheme.primary)
        .padding(14).background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
    }

    private var gapSummary: some View {
        let gaps = RecordingTimeline.gaps(in: session.chunks)
        return Group {
            if !gaps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("分段时间空档（估算）").font(.subheadline.bold())
                    ForEach(Array(gaps.prefix(20))) { gap in
                        Text("\(gap.start.formatted(date: .omitted, time: .standard)) — \(gap.end.formatted(date: .omitted, time: .standard)) · \(durationText(gap.duration, compact: false))\(gap.missingSegments > 0 ? " · 中间缺少分段" : "")")
                            .font(.caption)
                    }
                    if gaps.count > 20 { Text("另有 \(gaps.count - 20) 处空档").font(.caption) }
                    Text("按文件开始时间与音频时长估算；可能来自中断、未收齐或时钟变化，不是麦克风无缝录音的测量结果。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.foregroundStyle(RecorderTheme.warning).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func chunkCard(_ chunk: PhoneRecordingChunk) -> some View {
        let active = playback.isActive(chunk)
        return HStack(spacing: 12) {
            if isSelecting {
                Button {
                    if !selectedIDs.insert(chunk.id).inserted { selectedIDs.remove(chunk.id) }
                } label: {
                    Image(systemName: selectedIDs.contains(chunk.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(RecorderTheme.primary).frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(library.unavailableChunkIDs.contains(chunk.id) || exporter.isPreparing)
                .accessibilityLabel("选择第 \(chunk.sequence + 1) 段")
            }
            Button {
                playback.toggle(chunk: chunk, url: library.fileURL(for: chunk))
            } label: {
                ZStack {
                    Circle()
                        .fill(active ? RecorderTheme.primary : Color.white.opacity(0.08))
                    Image(systemName: active && playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active && playback.isPlaying ? "暂停第 \(chunk.sequence + 1) 段" : "播放第 \(chunk.sequence + 1) 段")

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("第 \(chunk.sequence + 1) 段")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(durationText(chunk.duration, compact: false))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.50))
                }

                if active {
                    ProgressView(value: playback.progress)
                        .tint(RecorderTheme.primary)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(RecorderTheme.success)
                        Text(chunk.startedAt, format: .dateTime.hour().minute().second())
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.42))
                }
            }

            ShareLink(item: library.fileURL(for: chunk)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导出第 \(chunk.sequence + 1) 段")
        }
        .padding(14)
        .background(RecorderTheme.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(RecorderTheme.stroke))
    }
}

private struct PhoneRecordingSession: Identifiable {
    let id: UUID
    let chunks: [PhoneRecordingChunk]
    let manifest: RecordingSessionManifest?
    let hasUnavailableFiles: Bool

    var startedAt: Date { manifest?.startedAt ?? chunks.first?.startedAt ?? .distantPast }
    var duration: TimeInterval { chunks.reduce(0) { $0 + $1.duration } }
    var byteCount: Int64 { chunks.reduce(0) { $0 + $1.byteCount } }

    var isContinuous: Bool {
        !hasUnavailableFiles && !chunks.isEmpty && ChunkSequenceValidator.isContinuous(chunks.map(\.sequence))
    }

    var isComplete: Bool { !hasUnavailableFiles && manifest?.receiptStatus(for: chunks) == .complete }
    var receiptTitle: String {
        if hasUnavailableFiles { return "手机本地文件缺失或校验异常，请检查原件" }
        return manifest?.receiptStatus(for: chunks).title ?? "等待手表场次清单，暂不能确认整场收齐"
    }

    static func group(_ chunks: [PhoneRecordingChunk], manifests: [RecordingSessionManifest], unavailableIDs: Set<UUID>) -> [PhoneRecordingSession] {
        let groups = Dictionary(grouping: chunks, by: \.sessionID)
        let allIDs = Set(groups.keys).union(manifests.map(\.id))
        return allIDs
            .map { id in
                PhoneRecordingSession(
                    id: id,
                    chunks: (groups[id] ?? []).sorted { $0.sequence < $1.sequence },
                    manifest: manifests.first(where: { $0.id == id }),
                    hasUnavailableFiles: (groups[id] ?? []).contains(where: { unavailableIDs.contains($0.id) })
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

private func durationText(_ seconds: TimeInterval, compact: Bool) -> String {
    let value = max(0, Int(seconds))
    let hours = value / 3600
    let minutes = (value / 60) % 60
    let remainingSeconds = value % 60
    if compact {
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分钟" }
        return "\(remainingSeconds)秒"
    }
    return String(format: "%02d:%02d", minutes + hours * 60, remainingSeconds)
}

private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
