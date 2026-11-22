import Foundation

enum RecordingDurationValidator {
    static func isPlausible(
        expected: TimeInterval,
        actual: TimeInterval
    ) -> Bool {
        guard expected.isFinite, actual.isFinite, expected > 0, actual > 0 else {
            return false
        }
        let allowedDrift = max(3, expected * 0.03)
        return abs(actual - expected) <= allowedDrift
    }
}
