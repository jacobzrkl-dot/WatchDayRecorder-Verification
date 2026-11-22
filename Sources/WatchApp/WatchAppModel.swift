import Combine
import Foundation

@MainActor
final class WatchAppModel: ObservableObject {
    let store: ChunkQueueStore
    let recorder: ChunkedRecorder
    let transfer: WatchTransferCoordinator
    let ledger: RecordingSessionLedger
    let recovery: WatchRecoveryController

    init() {
        let store = ChunkQueueStore()
        let ledger = RecordingSessionLedger()
        try? ledger.interruptOpenSessions()
        let transfer = WatchTransferCoordinator(store: store, ledger: ledger)
        let recorder = ChunkedRecorder(store: store, ledger: ledger)
        self.store = store
        self.transfer = transfer
        self.recorder = recorder
        self.ledger = ledger
        transfer.statusProvider = { [weak recorder, weak store] in
            guard let recorder, let store else { return nil }
            return recorder.companionStatus(pendingChunks: store.chunks.count)
        }
        recorder.onStateUpdated = { [weak transfer] in
            Task { @MainActor in transfer?.publishStatus() }
        }
        recovery = WatchRecoveryController(store: store, ledger: ledger, recorder: recorder,
            scheduleTransfers: { [weak transfer] in transfer?.scheduleEligibleTransfers(forceRetry: true) })
        recorder.onChunkFinalized = { [weak transfer] chunk in
            transfer?.enqueue(chunk)
        }
        recorder.onSessionUpdated = { [weak transfer] in
            // beginNewSession publishes its ledger before starting capture.
            // Defer until that synchronous transition finishes so the phone
            // cannot receive a transient, false "paused" notification.
            Task { @MainActor in transfer?.scheduleEligibleTransfers() }
        }
        transfer.scheduleEligibleTransfers()
    }
}
