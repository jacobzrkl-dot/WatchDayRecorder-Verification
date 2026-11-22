import SwiftUI

@main
struct WatchDayRecorderWatchApp: App {
    @StateObject private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView(
                recorder: model.recorder,
                store: model.store,
                transfer: model.transfer,
                ledger: model.ledger,
                recovery: model.recovery
            )
            .onOpenURL { url in
                guard AppRoute.isQuickRecord(url) else { return }
                model.recorder.startDaySession()
            }
        }
        .backgroundTask(.watchConnectivity) {
            await model.transfer.handleBackgroundWake()
        }
    }
}
