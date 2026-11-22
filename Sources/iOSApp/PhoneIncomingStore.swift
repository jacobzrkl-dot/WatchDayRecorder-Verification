import Foundation

struct PhoneIncomingDelivery: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let chunk: RecordingChunk
    let audioFilename: String
    let receivedAt: Date
}

/// A synchronous, crash-recoverable inbox used directly inside the
/// WatchConnectivity receive callback.
final class PhoneIncomingStore: @unchecked Sendable {
    let rootDirectory: URL

    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.rootDirectory = support
                .appendingPathComponent("WatchDayRecorder", isDirectory: true)
                .appendingPathComponent("Incoming", isDirectory: true)
        }
        try? fileManager.createDirectory(
            at: self.rootDirectory,
            withIntermediateDirectories: true
        )
    }

    func stage(fileURL: URL, chunk: RecordingChunk) throws -> PhoneIncomingDelivery {
        guard RecordingMetadataValidation.valid(chunk) else { throw CocoaError(.fileReadCorruptFile) }
        return try withLock {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            let deliveryID = UUID()
            let audioFilename = "\(deliveryID.uuidString).incoming.m4a"
            let delivery = PhoneIncomingDelivery(
                id: deliveryID,
                chunk: chunk,
                audioFilename: audioFilename,
                receivedAt: Date()
            )
            let metadataFile = metadataURL(for: deliveryID)
            let destination = rootDirectory.appendingPathComponent(audioFilename)

            // Persist the processing intent first. If the process dies before
            // the copy finishes, the next launch drops the incomplete intent
            // and waits for the Watch to redeliver because no ACK was sent.
            try AtomicJSONFile<PhoneIncomingDelivery>(url: metadataFile).save(delivery)
            do {
                try fileManager.copyItem(at: fileURL, to: destination)
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
            } catch {
                try? removeFiles(for: delivery)
                throw error
            }
            return delivery
        }
    }

    func pending() -> [PhoneIncomingDelivery] {
        withLock {
            let urls = (try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            let metadataURLs = Set(urls.compactMap { url -> URL? in
                if url.pathExtension == "json" { return url }
                if url.lastPathComponent.hasSuffix(".json.backup") {
                    return url.deletingPathExtension()
                }
                return nil
            })
            let records = metadataURLs
                .compactMap { self.loadDelivery(at: $0) }
                .filter { delivery in
                    let audioExists = fileManager.fileExists(
                        atPath: audioURL(for: delivery).path
                    )
                    // An interrupted staging attempt or a partially completed
                    // cleanup can leave only metadata. Retry that cleanup on
                    // each scan, including after relaunch; never touch audio
                    // belonging to a valid pending delivery.
                    if !audioExists { try? removeFiles(for: delivery) }
                    return audioExists
                }
            return records.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    func audioURL(for delivery: PhoneIncomingDelivery) -> URL {
        rootDirectory.appendingPathComponent(delivery.audioFilename)
    }

    func remove(_ delivery: PhoneIncomingDelivery) throws {
        guard valid(delivery) else { throw CocoaError(.fileReadCorruptFile) }
        try withLock {
            try removeFiles(for: delivery)
        }
    }

    private func metadataURL(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadDelivery(at url: URL) -> PhoneIncomingDelivery? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [url, url.appendingPathExtension("backup")] {
            if let data = try? Data(contentsOf: candidate),
               let delivery = try? decoder.decode(PhoneIncomingDelivery.self, from: data),
               valid(delivery), metadataURL(for: delivery.id).standardizedFileURL == url.standardizedFileURL {
                return delivery
            }
        }
        return nil
    }

    private func valid(_ delivery: PhoneIncomingDelivery) -> Bool {
        RecordingMetadataValidation.valid(delivery.chunk)
            && RecordingMetadataValidation.date(delivery.receivedAt)
            && delivery.audioFilename == "\(delivery.id.uuidString).incoming.m4a"
    }

    private func removeFiles(for delivery: PhoneIncomingDelivery) throws {
        let candidates = [
            audioURL(for: delivery),
            metadataURL(for: delivery.id),
            metadataURL(for: delivery.id).appendingPathExtension("backup")
        ]
        // Keep the processing intent until the audio has been removed. If
        // audio removal fails, deleting its metadata would orphan that file.
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
