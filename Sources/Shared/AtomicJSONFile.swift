import Foundation

struct AtomicJSONFile<Value: Codable> {
    let url: URL

    func load(default defaultValue: @autoclosure () -> Value) -> Value {
        if let value = decode(at: url) {
            return value
        }
        if let value = decode(at: backupURL) {
            return value
        }
        return defaultValue()
    }

    /// Only a genuinely absent index is an empty index. Permission failures
    /// and two invalid copies must not cause callers to overwrite old data.
    func loadIfPresent(default defaultValue: @autoclosure () -> Value) throws -> Value {
        var readError: Error?
        for candidate in [url, backupURL] {
            do {
                let data = try Data(contentsOf: candidate)
                return try Self.decoder.decode(Value.self, from: data)
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain
                    || nsError.code != NSFileReadNoSuchFileError {
                    readError = readError ?? error
                }
            }
        }
        if let readError { throw readError }
        return defaultValue()
    }

    func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(value)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try data.write(
            to: backupURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private var backupURL: URL {
        url.appendingPathExtension("backup")
    }

    private func decode(at candidate: URL) -> Value? {
        guard let data = try? Data(contentsOf: candidate) else { return nil }
        return try? Self.decoder.decode(Value.self, from: data)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
