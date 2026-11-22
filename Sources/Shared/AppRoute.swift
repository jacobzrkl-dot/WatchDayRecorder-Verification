import Foundation

enum AppRoute {
    static let scheme = "watchdayrecorder"
    static let quickRecordURL = URL(string: "watchdayrecorder://record")!

    static func isQuickRecord(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == "record"
    }
}
