import XCTest
@testable import WatchDayRecorder

final class CompanionSetupStateTests: XCTestCase {
    func testActivatedServiceCannotHideMissingPairingOrInstallation() {
        XCTAssertEqual(CompanionSetupState.resolve(supported: true, activated: true, failed: false, paired: false, installed: true), .unpaired)
        XCTAssertEqual(CompanionSetupState.resolve(supported: true, activated: true, failed: false, paired: true, installed: false), .missingApp)
        XCTAssertEqual(CompanionSetupState.resolve(supported: true, activated: true, failed: false, paired: true, installed: true), .ready)
    }

    func testActivationFailureDoesNotDisplayEndlessChecking() {
        XCTAssertEqual(CompanionSetupState.resolve(supported: true, activated: false, failed: true, paired: true, installed: true), .failed)
        XCTAssertEqual(CompanionSetupState.resolve(supported: true, activated: false, failed: false, paired: true, installed: true), .activating)
        XCTAssertEqual(CompanionSetupState.resolve(supported: false, activated: false, failed: false, paired: false, installed: false), .unsupported)
    }
}
