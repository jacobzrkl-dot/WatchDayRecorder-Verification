import Foundation
import XCTest
@testable import WatchDayRecorder

final class RecorderHealthMonitorTests: XCTestCase {
    func testAdvancingAudioDoesNotStallWhenTimersAreDelayed() {
        var monitor = RecorderHealthMonitor()
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 1, uptime: 1))
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 40, uptime: 40))
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 41, uptime: 41))
    }

    func testFrozenClockWhileFlagStillTrueEventuallyStalls() {
        var monitor = RecorderHealthMonitor()
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 1, uptime: 1))
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 1, uptime: 2))
        XCTAssertTrue(monitor.isStalled(isRecording: true, audioTime: 1, uptime: 6))
    }

    func testStoppedRecorderGetsGraceForNormalCompletionCallback() {
        var monitor = RecorderHealthMonitor()
        XCTAssertFalse(monitor.isStalled(isRecording: false, audioTime: 0, uptime: 600))
        XCTAssertFalse(monitor.isStalled(isRecording: false, audioTime: 0, uptime: 601))
        XCTAssertTrue(monitor.isStalled(isRecording: false, audioTime: 0, uptime: 604))
    }

    func testRecoveredAudioClockClearsSuspicion() {
        var monitor = RecorderHealthMonitor()
        _ = monitor.isStalled(isRecording: true, audioTime: 1, uptime: 1)
        _ = monitor.isStalled(isRecording: true, audioTime: 1, uptime: 2)
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 2, uptime: 3))
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: 3, uptime: 10))
    }

    func testInvalidAudioClockCannotAppearHealthy() {
        var monitor = RecorderHealthMonitor()
        XCTAssertFalse(monitor.isStalled(isRecording: true, audioTime: .nan, uptime: 1))
        XCTAssertTrue(monitor.isStalled(isRecording: true, audioTime: .infinity, uptime: 5))
    }

    func testBackgroundDrainWaitsForActivationContentAndLocalCallbacks() {
        XCTAssertFalse(ConnectivityDrainPolicy.canComplete(activated: false, hasContentPending: false, pendingCallbacks: 0))
        XCTAssertFalse(ConnectivityDrainPolicy.canComplete(activated: true, hasContentPending: true, pendingCallbacks: 0))
        XCTAssertFalse(ConnectivityDrainPolicy.canComplete(activated: true, hasContentPending: false, pendingCallbacks: 1))
        XCTAssertTrue(ConnectivityDrainPolicy.canComplete(activated: true, hasContentPending: false, pendingCallbacks: 0))
    }

    func testDelegateCounterKeepsBackgroundWorkVisibleUntilAllCallbacksFinish() {
        let counter = DelegateWorkCounter()
        counter.begin()
        counter.begin()
        counter.end()
        XCTAssertEqual(counter.pending, 1)
        counter.end()
        XCTAssertEqual(counter.pending, 0)
    }
}
