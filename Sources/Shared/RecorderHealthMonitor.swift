import Foundation

/// Observe the recorder's sample clock, not just a wall-clock label.
struct RecorderHealthMonitor {
    private var lastAudioTime: TimeInterval?
    private var unhealthySince: TimeInterval?
    let gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = 4) { self.gracePeriod = gracePeriod }

    mutating func isStalled(isRecording: Bool, audioTime: TimeInterval, uptime: TimeInterval) -> Bool {
        guard uptime.isFinite else { return false }
        let advanced = audioTime.isFinite && audioTime >= 0
            && (lastAudioTime == nil || audioTime > (lastAudioTime ?? 0) + 0.01)
        if isRecording && advanced {
            unhealthySince = nil
        } else if unhealthySince == nil {
            unhealthySince = uptime
        }
        if audioTime.isFinite { lastAudioTime = audioTime }
        return unhealthySince.map { uptime - $0 >= gracePeriod } ?? false
    }
}

enum ConnectivityDrainPolicy {
    static func canComplete(activated: Bool, hasContentPending: Bool, pendingCallbacks: Int) -> Bool {
        activated && !hasContentPending && pendingCallbacks == 0
    }
}

/// Delegate work is counted before hopping to the main actor, so the Watch
/// background handler cannot finish while an ACK is still queued locally.
final class DelegateWorkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var pending: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        count = max(0, count - 1)
    }
}
