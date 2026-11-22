import AVFoundation
import Foundation
#if os(watchOS)
import WatchKit
#endif

@MainActor
protocol RecordingDevice: AnyObject {
    var url: URL { get }
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    var onFinished: ((URL, TimeInterval, Bool) -> Void)? { get set }
    var onError: ((URL, TimeInterval, String?) -> Void)? { get set }
    func prepareToRecord() -> Bool
    func record(forDuration duration: TimeInterval) -> Bool
    func stop()
}

enum RecordingAuthorization { case granted, denied, undetermined }
enum RecordingFeedback { case started, stopped, failure }

@MainActor
struct RecorderEnvironment {
    var makeDevice: (URL, [String: Any]) throws -> any RecordingDevice
    var configureSession: () throws -> Void
    var activateSession: () throws -> Void
    var deactivateSession: () -> Void
    var authorization: () -> RecordingAuthorization
    var requestAuthorization: (@escaping @Sendable (Bool) -> Void) -> Void
    var batteryLevel: () -> Float
    var feedback: (RecordingFeedback) -> Void

    static func live() -> Self {
        #if os(watchOS)
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        #endif
        return Self(
            makeDevice: { try SystemRecordingDevice(url: $0, settings: $1) },
            configureSession: { try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: []) },
            activateSession: { try AVAudioSession.sharedInstance().setActive(true) },
            deactivateSession: { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) },
            authorization: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted: .granted
                case .denied: .denied
                case .undetermined: .undetermined
                @unknown default: .denied
                }
            },
            requestAuthorization: { completion in AVAudioApplication.requestRecordPermission(completionHandler: completion) },
            batteryLevel: {
                #if os(watchOS)
                WKInterfaceDevice.current().batteryLevel
                #else
                -1
                #endif
            },
            feedback: { feedback in
                #if os(watchOS)
                switch feedback {
                case .started: WKInterfaceDevice.current().play(.start)
                case .stopped: WKInterfaceDevice.current().play(.stop)
                case .failure: WKInterfaceDevice.current().play(.failure)
                }
                #endif
            }
        )
    }
}

@MainActor
private final class SystemRecordingDevice: NSObject, RecordingDevice, AVAudioRecorderDelegate {
    private let recorder: AVAudioRecorder
    var url: URL { recorder.url }
    var currentTime: TimeInterval { recorder.currentTime }
    var isRecording: Bool { recorder.isRecording }
    var onFinished: ((URL, TimeInterval, Bool) -> Void)?
    var onError: ((URL, TimeInterval, String?) -> Void)?

    init(url: URL, settings: [String: Any]) throws {
        recorder = try AVAudioRecorder(url: url, settings: settings)
        super.init()
        recorder.delegate = self
        recorder.isMeteringEnabled = false
    }

    func prepareToRecord() -> Bool { recorder.prepareToRecord() }
    func record(forDuration duration: TimeInterval) -> Bool { recorder.record(forDuration: duration) }
    func stop() { recorder.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        let duration = recorder.currentTime
        Task { @MainActor [weak self] in self?.onFinished?(url, duration, flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        let duration = recorder.currentTime
        let description = error?.localizedDescription
        Task { @MainActor [weak self] in self?.onError?(url, duration, description) }
    }
}
