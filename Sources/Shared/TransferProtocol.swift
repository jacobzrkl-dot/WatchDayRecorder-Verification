import CoreFoundation
import Foundation

struct ChunkAcknowledgement: Equatable, Sendable {
    let chunkID: UUID
    let sha256: String
    let accepted: Bool
    let reason: String?
}

enum TransferProtocol {
    static let schemaVersion = 1
    static let transferKind = "recordingChunk"
    static let acknowledgementKind = "chunkAcknowledgement"
    static let retryRequestKind = "retryPendingChunks"
    static let manifestKind = "sessionManifest"
    static let manifestAcknowledgementKind = "sessionManifestAcknowledgement"
    static let diagnosticsRequestKind = "requestDiagnostics"
    static let diagnosticsFileKind = "watchDiagnostics"
    static let statusKind = "watchCaptureStatus"
    static let statusRequestKind = "requestCaptureStatus"

    static func request(_ kind: String) -> [String: Any] {
        [Key.kind: kind, Key.schemaVersion: schemaVersion]
    }
    static func isKind(_ kind: String, _ payload: [String: Any]) -> Bool {
        payload[Key.kind] as? String == kind && intValue(payload[Key.schemaVersion]) == schemaVersion
    }
    static func statusPayload(_ status: WatchCaptureStatus) throws -> [String: Any] {
        var payload = request(statusKind)
        payload["status"] = try JSONEncoder().encode(status)
        return payload
    }
    static func parseStatus(_ payload: [String: Any]) -> WatchCaptureStatus? {
        guard isKind(statusKind, payload), let data = payload["status"] as? Data, data.count <= 8192,
              let status = try? JSONDecoder().decode(WatchCaptureStatus.self, from: data), status.isValid else { return nil }
        return status
    }
    static func hasUnsupportedVersion(_ payload: [String: Any]) -> Bool {
        guard let kind = payload[Key.kind] as? String,
              [transferKind, acknowledgementKind, retryRequestKind, manifestKind, manifestAcknowledgementKind,
               diagnosticsRequestKind, diagnosticsFileKind, statusKind, statusRequestKind].contains(kind) else { return false }
        return intValue(payload[Key.schemaVersion]) != schemaVersion
    }

    static func manifestPayload(_ manifest: RecordingSessionManifest) throws -> [String: Any] {
        [Key.kind: manifestKind, Key.schemaVersion: schemaVersion,
         "manifest": try JSONEncoder().encode(manifest)]
    }

    static func parseManifest(_ payload: [String: Any]) -> RecordingSessionManifest? {
        guard payload[Key.kind] as? String == manifestKind,
              intValue(payload[Key.schemaVersion]) == schemaVersion,
              let data = payload["manifest"] as? Data,
              let manifest = try? JSONDecoder().decode(RecordingSessionManifest.self, from: data),
              manifest.isValid else { return nil }
        return manifest
    }

    static func manifestAcknowledgement(_ manifest: RecordingSessionManifest) -> [String: Any] {
        [Key.kind: manifestAcknowledgementKind, Key.schemaVersion: schemaVersion,
         Key.sessionID: manifest.id.uuidString, "revision": manifest.revision]
    }

    static func parseManifestAcknowledgement(_ payload: [String: Any]) -> (id: UUID, revision: Int)? {
        guard payload[Key.kind] as? String == manifestAcknowledgementKind,
              intValue(payload[Key.schemaVersion]) == schemaVersion,
              let idString = payload[Key.sessionID] as? String,
              let id = UUID(uuidString: idString),
              let revision = intValue(payload["revision"]), revision > 0 else { return nil }
        return (id, revision)
    }

    static func retryRequest() -> [String: Any] {
        [Key.kind: retryRequestKind, Key.schemaVersion: schemaVersion]
    }

    static func isRetryRequest(_ payload: [String: Any]) -> Bool {
        payload[Key.kind] as? String == retryRequestKind
            && intValue(payload[Key.schemaVersion]) == schemaVersion
    }

    enum Key {
        static let kind = "kind"
        static let schemaVersion = "schemaVersion"
        static let chunkID = "chunkID"
        static let sessionID = "sessionID"
        static let sequence = "sequence"
        static let filename = "filename"
        static let startedAt = "startedAt"
        static let duration = "duration"
        static let byteCount = "byteCount"
        static let sha256 = "sha256"
        static let accepted = "accepted"
        static let reason = "reason"
    }

    static func metadata(for chunk: RecordingChunk) -> [String: Any] {
        [
            Key.kind: transferKind,
            Key.schemaVersion: schemaVersion,
            Key.chunkID: chunk.id.uuidString,
            Key.sessionID: chunk.sessionID.uuidString,
            Key.sequence: chunk.sequence,
            Key.filename: chunk.filename,
            Key.startedAt: chunk.startedAt.timeIntervalSince1970,
            Key.duration: chunk.duration,
            Key.byteCount: chunk.byteCount,
            Key.sha256: chunk.sha256
        ]
    }

    static func chunk(from metadata: [String: Any]) -> RecordingChunk? {
        guard
            metadata[Key.kind] as? String == transferKind,
            intValue(metadata[Key.schemaVersion]) == schemaVersion,
            let chunkString = metadata[Key.chunkID] as? String,
            let chunkID = UUID(uuidString: chunkString),
            let sessionString = metadata[Key.sessionID] as? String,
            let sessionID = UUID(uuidString: sessionString),
            let sequence = intValue(metadata[Key.sequence]),
            let filename = metadata[Key.filename] as? String,
            let startedAtValue = doubleValue(metadata[Key.startedAt]),
            let duration = doubleValue(metadata[Key.duration]),
            let byteCount = int64Value(metadata[Key.byteCount]),
            let sha256 = metadata[Key.sha256] as? String,
            sha256.count == 64,
            startedAtValue.isFinite,
            duration.isFinite,
            duration > 0,
            byteCount > 0,
            sequence >= 0
        else {
            return nil
        }

        let chunk = RecordingChunk(
            id: chunkID,
            sessionID: sessionID,
            sequence: sequence,
            filename: filename,
            startedAt: Date(timeIntervalSince1970: startedAtValue),
            duration: duration,
            byteCount: byteCount,
            sha256: sha256
        )
        return RecordingMetadataValidation.valid(chunk) ? chunk : nil
    }

    static func acknowledgement(
        chunkID: UUID,
        sha256: String,
        accepted: Bool,
        reason: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            Key.kind: acknowledgementKind,
            Key.schemaVersion: schemaVersion,
            Key.chunkID: chunkID.uuidString,
            Key.sha256: sha256,
            Key.accepted: accepted
        ]
        if let reason {
            payload[Key.reason] = reason
        }
        return payload
    }

    static func parseAcknowledgement(
        _ payload: [String: Any]
    ) -> ChunkAcknowledgement? {
        guard
            payload[Key.kind] as? String == acknowledgementKind,
            intValue(payload[Key.schemaVersion]) == schemaVersion,
            let idString = payload[Key.chunkID] as? String,
            let chunkID = UUID(uuidString: idString),
            let sha256 = payload[Key.sha256] as? String,
            let accepted = payload[Key.accepted] as? Bool,
            let flag = payload[Key.accepted] as? NSNumber,
            CFGetTypeID(flag) == CFBooleanGetTypeID(),
            RecordingMetadataValidation.checksum(sha256)
        else {
            return nil
        }
        return ChunkAcknowledgement(
            chunkID: chunkID,
            sha256: sha256,
            accepted: accepted,
            reason: payload[Key.reason] as? String
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = integerNumber(value) else { return nil }
        return Int(exactly: number.int64Value)
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        integerNumber(value)?.int64Value
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func integerNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.decimalValue == Decimal(number.int64Value) else { return nil }
        return number
    }
}
