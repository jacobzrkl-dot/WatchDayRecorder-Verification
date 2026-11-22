import AVFoundation
import XCTest
@testable import WatchDayRecorder

final class ChunkedRecorderFlowTests: XCTestCase {
    @MainActor
    func testRolloverStartsNextCaptureBeforePersistenceAndTransferCallback() throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        var nextWasRecordingAtCommit = false
        harness.controller.onChunkFinalized = { _ in
            nextWasRecordingAtCommit = harness.devices.count == 2 && harness.devices[1].isRecording
        }
        harness.controller.startDaySession()
        harness.devices[0].complete()
        XCTAssertTrue(nextWasRecordingAtCommit, "Disk work and transfer scheduling must not delay the next capture")
        XCTAssertEqual(harness.store.chunks.map(\.sequence), [0])
        XCTAssertEqual(harness.controller.currentSequence, 1)
        XCTAssertTrue(harness.controller.isRecording)
    }

    @MainActor
    func testRolloverRetriesUnavailableDeviceWithoutLosingFinishedChunkOrSequence() async throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        harness.shouldStart = false
        harness.devices[0].complete()
        XCTAssertEqual(harness.store.chunks.map(\.sequence), [0])
        XCTAssertEqual(harness.controller.currentSequence, 1)
        XCTAssertTrue(harness.controller.isSessionActive)
        XCTAssertFalse(harness.controller.isRecording)
        harness.shouldStart = true
        await waitUntil { harness.controller.isRecording }
        XCTAssertEqual(harness.devices.count, 3)
        harness.controller.stopDaySession()
        harness.devices[2].complete()
        XCTAssertEqual(harness.store.chunks.map(\.sequence), [0, 1])
        XCTAssertFalse(harness.controller.isSessionActive)
        XCTAssertTrue(try XCTUnwrap(harness.ledger.manifests.first).wasInterrupted)
    }

    @MainActor
    func testRapidStopStartAndLateDuplicateCallbackCannotMixSessions() throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        let old = harness.devices[0]
        harness.controller.stopDaySession()
        harness.controller.startDaySession()
        XCTAssertEqual(harness.devices.count, 1)
        old.complete()
        harness.controller.startDaySession()
        XCTAssertEqual(harness.devices.count, 2)
        old.complete()
        XCTAssertEqual(harness.store.chunks.count, 1)
        XCTAssertTrue(harness.controller.isRecording)
        XCTAssertEqual(harness.controller.currentSequence, 0)
    }

    @MainActor
    func testInterruptionEndBeforeFinalizationStartsExactlyOneReplacement() async throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        harness.interrupt(.began)
        harness.interrupt(.ended, resume: true)
        XCTAssertEqual(harness.devices.count, 1)
        harness.devices[0].complete()
        await waitUntil { harness.devices.count == 2 }
        harness.interrupt(.ended, resume: true)
        XCTAssertEqual(harness.devices.count, 2)
        XCTAssertTrue(harness.controller.isRecording)
    }

    @MainActor
    func testMissingEndNotificationAllowsManualRetryAndIgnoresLateEnd() async throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        harness.interrupt(.began)
        harness.devices[0].complete()
        XCTAssertTrue(harness.controller.isWaitingForResume)
        harness.controller.resumeAfterInterruption()
        await waitUntil { harness.devices.count == 2 }
        harness.interrupt(.ended, resume: true)
        XCTAssertEqual(harness.devices.count, 2)
        XCTAssertTrue(harness.controller.isRecording)
    }

    @MainActor
    func testMediaResetPreservesPartialAndRejectsAlreadyQueuedOldCallback() throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        let old = harness.devices[0]
        let queuedCallback = try XCTUnwrap(old.onFinished)
        harness.controller.handleMediaServicesUnavailable()
        XCTAssertFalse(harness.controller.isSessionActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertTrue(try XCTUnwrap(harness.ledger.manifests.first).requiresRecovery)
        harness.controller.startDaySession()
        queuedCallback(old.url, 1, true)
        XCTAssertEqual(harness.store.chunks.count, 0)
        XCTAssertTrue(harness.controller.isRecording)
    }

    @MainActor
    func testFailedDeviceStartClosesSessionWithoutClaimingRecording() throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.shouldStart = false
        harness.controller.startDaySession()
        XCTAssertFalse(harness.controller.isRecording)
        XCTAssertFalse(harness.controller.isSessionActive)
        XCTAssertNotNil(harness.controller.lastError)
        XCTAssertNotNil(harness.ledger.manifests.first?.endedAt)
        XCTAssertTrue(harness.store.chunks.isEmpty)
    }

    @MainActor
    func testPersistenceFailureAfterRestartSafelyStopsNewCaptureAndRetainsBothFiles() throws {
        let harness = try RecorderHarness()
        defer { harness.cleanup() }
        harness.controller.startDaySession()
        let queueFile = harness.queueRoot.appendingPathComponent("chunk-queue.json")
        try FileManager.default.removeItem(at: queueFile)
        try FileManager.default.createDirectory(at: queueFile, withIntermediateDirectories: false)
        harness.devices[0].complete()
        guard harness.devices.count == 2 else { return XCTFail("Rollover must start the next device before disk work") }
        XCTAssertFalse(harness.devices[1].isRecording)
        XCTAssertFalse(harness.controller.isSessionActive)
        XCTAssertNotNil(harness.controller.lastError)
        for device in harness.devices {
            XCTAssertTrue(FileManager.default.fileExists(atPath: device.url.path))
        }
        harness.devices[1].complete(success: false)
        XCTAssertFalse(harness.controller.isFinalizing)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class RecorderHarness {
    let root: URL
    let queueRoot: URL
    let store: ChunkQueueStore
    let ledger: RecordingSessionLedger
    var devices: [TestRecordingDevice] = []
    var shouldStart = true
    lazy var controller: ChunkedRecorder = {
        let environment = RecorderEnvironment(
            makeDevice: { [unowned self] url, _ in
                try AudioTestFixture.writeAAC(to: url)
                let device = TestRecordingDevice(url: url, shouldStart: self.shouldStart)
                self.devices.append(device)
                return device
            }, configureSession: {}, activateSession: {}, deactivateSession: {},
            authorization: { .granted }, requestAuthorization: { $0(true) },
            batteryLevel: { 1 }, feedback: { _ in })
        return ChunkedRecorder(store: store, ledger: ledger, environment: environment)
    }()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        queueRoot = root.appendingPathComponent("Queue")
        store = ChunkQueueStore(rootDirectory: queueRoot)
        ledger = RecordingSessionLedger(rootDirectory: root.appendingPathComponent("Ledger"))
    }

    func interrupt(_ type: AVAudioSession.InterruptionType, resume: Bool = false) {
        controller.handleAudioInterruption(typeRawValue: type.rawValue,
            optionsRawValue: resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0)
    }

    func cleanup() {
        controller.onChunkFinalized = nil
        controller.onSessionUpdated = nil
        controller.stopDaySession()
        for device in devices {
            if device.onFinished != nil { device.complete(success: false) }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class TestRecordingDevice: RecordingDevice {
    let url: URL
    let shouldStart: Bool
    var currentTime: TimeInterval = 1
    var isRecording = false
    var onFinished: ((URL, TimeInterval, Bool) -> Void)?
    var onError: ((URL, TimeInterval, String?) -> Void)?
    init(url: URL, shouldStart: Bool) { self.url = url; self.shouldStart = shouldStart }
    func prepareToRecord() -> Bool { true }
    func record(forDuration duration: TimeInterval) -> Bool { isRecording = shouldStart; return shouldStart }
    func stop() { isRecording = false }
    func complete(success: Bool = true) { isRecording = false; onFinished?(url, currentTime, success) }
}
