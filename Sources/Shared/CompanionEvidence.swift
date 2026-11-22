import Foundation

struct WatchCaptureStatus: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case recording, paused, saving, stopped, error }
    let timestamp: Date
    let mode: Mode
    let pendingChunks: Int
    let battery: Float
    let error: String?

    var isValid: Bool {
        RecordingMetadataValidation.date(timestamp) && pendingChunks >= 0 && pendingChunks <= 1_000_000
            && battery.isFinite && battery >= -1 && battery <= 1 && (error?.count ?? 0) <= 2000
    }
    func summary(at now: Date = Date()) -> String {
        guard now.timeIntervalSince(timestamp) >= -300, now.timeIntervalSince(timestamp) <= 180 else {
            return "手表状态已过期，可能离线，暂时无法确认是否仍在录音"
        }
        switch mode {
        case .recording: return "手表最近报告：录音中"
        case .paused: return "手表报告录音中断，请到手表检查并继续"
        case .saving: return "手表正在保存最后一段"
        case .stopped: return "手表最近报告：已停止"
        case .error: return "手表报告异常：\(error ?? "请检查手表")"
        }
    }
    func shouldNotify(after previous: WatchCaptureStatus?, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return age >= -300 && age <= 180 && (mode == .paused || mode == .error)
            && (previous?.mode != mode || previous?.error != error
                || previous.map { !(-300.0...180.0).contains(now.timeIntervalSince($0.timestamp)) } == true)
    }
    func needsPublication(after previous: WatchCaptureStatus?, force: Bool = false) -> Bool {
        guard !force, let previous else { return true }
        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        return previous.mode != mode || previous.error != error || previous.pendingChunks != pendingChunks
            || elapsed < 0 || elapsed >= 60
    }
}

struct DiagnosticSnapshot: Codable, Sendable {
    let generatedAt: Date
    let platform: String
    let appVersion: String
    let context: [String: String]
    let events: [DiagnosticEvent]
}

struct DiagnosticReport: Codable, Sendable {
    let schema: Int
    let generatedAt: Date
    let platform: String
    let appVersion: String
    let context: [String: String]
    let events: [DiagnosticEvent]
    var watch: DiagnosticSnapshot?
    var snapshot: DiagnosticSnapshot {
        DiagnosticSnapshot(generatedAt: generatedAt, platform: platform, appVersion: appVersion, context: context, events: events)
    }
}

/// Persistent, bounded companion evidence; never stores audio.
final class CompanionEvidenceStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()
    init(rootDirectory: URL? = nil) {
        root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchDayRecorder/CompanionEvidence", isDirectory: true)
    }
    func status() -> WatchCaptureStatus? {
        lock.lock(); defer { lock.unlock() }
        let value = readStatus()
        return value?.isValid == true ? value : nil
    }
    @discardableResult
    func save(_ status: WatchCaptureStatus, now: Date = Date()) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard status.isValid, status.timestamp <= now.addingTimeInterval(300) else { throw CocoaError(.fileReadCorruptFile) }
        let previous = readStatus()
        if let previous, previous.isValid, previous.timestamp <= now.addingTimeInterval(300), previous.timestamp >= status.timestamp { return false }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Preserve subsecond ordering for rapid start/stop reports. The shared
        // ISO8601 index encoder intentionally has whole-second precision.
        try JSONEncoder().encode(status).write(to: root.appendingPathComponent("status.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
    private func readStatus() -> WatchCaptureStatus? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("status.json")) else { return nil }
        return try? JSONDecoder().decode(WatchCaptureStatus.self, from: data)
    }
    func diagnostics() -> DiagnosticSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return read("watch-diagnostics.json")
    }
    func acceptDiagnostics(_ data: Data, now: Date = Date()) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReport.self, from: data)
        guard report.schema == 1, report.watch == nil, report.events.count <= 1000,
              report.context.count <= 30, report.context.allSatisfy({ $0.key.count <= 100 && $0.value.count <= 2000 }),
              report.platform.count <= 500, report.appVersion.count <= 100,
              RecordingMetadataValidation.date(report.generatedAt),
              report.generatedAt <= now.addingTimeInterval(300),
              report.events.allSatisfy({ event in
                  RecordingMetadataValidation.date(event.timestamp) && event.component.count <= 40 && event.code.count <= 80
                    && event.details.count <= 12 && event.details.allSatisfy { $0.key.count <= 100 && $0.value.count <= 500 }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        lock.lock(); defer { lock.unlock() }
        let previous: DiagnosticSnapshot? = read("watch-diagnostics.json")
        if let previous, previous.generatedAt <= now.addingTimeInterval(300), previous.generatedAt > report.generatedAt { return }
        try AtomicJSONFile<DiagnosticSnapshot>(url: root.appendingPathComponent("watch-diagnostics.json")).save(report.snapshot)
    }
    private func read<T: Decodable>(_ filename: String) -> T? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let url = root.appendingPathComponent(filename)
        for candidate in [url, url.appendingPathExtension("backup")] {
            if let data = try? Data(contentsOf: candidate), let result = try? decoder.decode(T.self, from: data) { return result }
        }
        return nil
    }
}
