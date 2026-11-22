import Combine
import Foundation

struct SessionPresentationMetadata: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var isArchived: Bool
}

@MainActor
final class PhoneSessionCatalog: ObservableObject {
    @Published private(set) var entries: [SessionPresentationMetadata] = []
    @Published private(set) var lastError: String?
    private let file: AtomicJSONFile<[SessionPresentationMetadata]>
    private var isReadable = true

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchDayRecorder", isDirectory: true)
        file = AtomicJSONFile(url: root.appendingPathComponent("session-catalog.json"))
        do {
            let loaded = try file.loadIfPresent(default: [])
            guard Set(loaded.map(\.id)).count == loaded.count else { throw CatalogError.invalidData }
            entries = loaded
        } catch {
            isReadable = false
            lastError = "录音名称与归档记录无法读取，原始音频不受影响，请解锁后重启"
        }
    }

    func title(for id: UUID) -> String? {
        guard let value = entries.first(where: { $0.id == id })?.title, !value.isEmpty else { return nil }
        return value
    }

    func isArchived(_ id: UUID) -> Bool { entries.first(where: { $0.id == id })?.isArchived ?? false }

    func rename(_ id: UUID, title: String) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 80 else { throw CatalogError.invalidTitle }
        try update(id) { $0.title = normalized }
    }

    func setArchived(_ id: UUID, _ archived: Bool) throws {
        try update(id) { $0.isArchived = archived }
    }

    func restoreMissing(_ restored: [SessionPresentationMetadata]) throws {
        guard isReadable, Set(restored.map(\.id)).count == restored.count,
              restored.allSatisfy({ $0.title.count <= 80 }) else { throw CatalogError.invalidData }
        let known = Set(entries.map(\.id))
        let updated = entries + restored.filter { !known.contains($0.id) }
        try file.save(updated)
        entries = updated
    }

    private func update(_ id: UUID, mutation: (inout SessionPresentationMetadata) -> Void) throws {
        guard isReadable else { throw CatalogError.invalidData }
        var updated = entries
        let index: Int
        if let existing = updated.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            updated.append(SessionPresentationMetadata(id: id, title: "", isArchived: false))
            index = updated.count - 1
        }
        mutation(&updated[index])
        do {
            try file.save(updated)
            entries = updated
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}

private enum CatalogError: LocalizedError {
    case invalidTitle, invalidData
    var errorDescription: String? {
        switch self {
        case .invalidTitle: "名称需要填写 1 至 80 个字符"
        case .invalidData: "名称与归档记录暂不可写入，请解锁后重启应用"
        }
    }
}

enum RecordingSearch {
    static func matches(query: String, title: String?, date: Date) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let searchable = [title ?? "", formatter.string(from: date), date.formatted(date: .abbreviated, time: .shortened)]
            .joined(separator: " ")
        return searchable.localizedStandardContains(query)
    }
}
