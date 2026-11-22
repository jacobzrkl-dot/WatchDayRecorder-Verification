import Combine
import Foundation

@MainActor
final class PhoneAppModel: ObservableObject {
    let library: PhoneRecordingLibrary
    let receiver: PhoneConnectivityReceiver
    let ledger: RecordingSessionLedger
    let catalog: PhoneSessionCatalog

    init() {
        let library = PhoneRecordingLibrary()
        let ledger = RecordingSessionLedger()
        self.library = library
        self.ledger = ledger
        catalog = PhoneSessionCatalog()
        receiver = PhoneConnectivityReceiver(library: library, ledger: ledger)
    }
}
