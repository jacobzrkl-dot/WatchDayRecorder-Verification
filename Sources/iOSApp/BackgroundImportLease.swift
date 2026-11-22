import UIKit

@MainActor
protocol ImportProcessingLease: AnyObject {
    var isExpired: Bool { get }
    var onExpiration: (() -> Void)? { get set }
    func finish()
}

@MainActor
final class BackgroundImportLease: ImportProcessingLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private(set) var isExpired = false
    var onExpiration: (() -> Void)? {
        didSet { if isExpired { onExpiration?() } }
    }

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "ValidateWatchChunk") { @MainActor [weak self] in
            // UIKit invokes expiration synchronously on the main thread.
            // End the assertion before returning, not in a later Task.
            self?.isExpired = true
            self?.onExpiration?()
            self?.finish()
        }
        if identifier == .invalid, UIApplication.shared.applicationState != .active {
            isExpired = true
        }
        if isExpired { finish() }
    }

    func finish() {
        onExpiration = nil
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
