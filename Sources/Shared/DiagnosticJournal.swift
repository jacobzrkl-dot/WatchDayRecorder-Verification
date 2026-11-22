import Foundation

struct DiagnosticEvent: Codable, Sendable {
    let timestamp: Date
    let component: String
    let code: String
    let details: [String: String]
}

/// Bounded, local metadata only. Logging failure must never abort capture/import.
final class DiagnosticJournal: @unchecked Sendable {
    static let shared = DiagnosticJournal()
    private let lock = NSLock()
    private let url: URL
    private let limit: Int
    private var events: [DiagnosticEvent]

    init(rootDirectory: URL? = nil, limit: Int = 1000) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchDayRecorder/Diagnostics", isDirectory: true)
        url = root.appendingPathComponent("events.json")
        self.limit = min(1000, max(1, limit))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([DiagnosticEvent].self, from: $0) } ?? []
        events = Array(loaded.suffix(self.limit))
    }

    @discardableResult
    func record(_ component: String, _ code: String, details: [String: String] = [:]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        events.append(DiagnosticEvent(timestamp: Date(), component: String(component.prefix(40)),
            code: String(code.prefix(80)), details: Dictionary(uniqueKeysWithValues:
                details.sorted(by: { $0.key < $1.key }).prefix(12).map { ($0.key, String($0.value.prefix(500))) })))
        events = Array(events.suffix(limit))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var directory = url.deletingLastPathComponent()
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try? directory.setResourceValues(resources)
            try Self.encoder().encode(events).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { return false }
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func export(context: [String: String], watch: DiagnosticSnapshot? = nil) throws -> URL {
        let report = DiagnosticReport(schema: 1, generatedAt: Date(), platform: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            context: context, events: snapshot(), watch: watch)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecorderDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("WatchDayRecorder-diagnostics_\(UUID().uuidString).json")
        try Self.encoder().encode(report).write(to: destination, options: .atomic)
        return destination
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
