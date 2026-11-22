import SwiftUI

@main
struct WatchDayRecorderApp: App {
    @StateObject private var model = PhoneAppModel()

    var body: some Scene {
        WindowGroup {
            PhoneContentView(library: model.library, receiver: model.receiver, ledger: model.ledger, catalog: model.catalog)
        }
    }
}
