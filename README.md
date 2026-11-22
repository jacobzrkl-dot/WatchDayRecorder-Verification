# WatchDayRecorder verification snapshot

Public source snapshot for standard GitHub-hosted macOS verification.
Includes iPhone, Apple Watch and widget sources, regression tests, XcodeGen
configuration and verification scripts. Private repository history, user
recordings, device certificates, provisioning profiles and local reports are
not included. Tests generate their own short synthetic audio fixtures.

The workflow uses the standard `macos-15` runner, without device signing.
It compiles the targets, runs all XCTest methods and captures simulator startup.
See Actions for the result of the exact source revision. Passing simulator
checks do not establish physical-device transport, all-day recording endurance
or an installable signed app.

Generate the project using `xcodegen generate`. On macOS with Xcode and the
simulator runtimes installed, run `bash scripts/verify-macos.sh`.
For local diagnostic configuration, set `WATCHDAY_SWIFT_RUNTIME` and
`WATCHDAY_SWIFT_GRAMMAR` to the existing Tree-sitter runtime/grammar paths.
`python scripts/check-project.py --cloud` reads the repository's Actions results.

Third-party references are documented in THIRD_PARTY_NOTICES.md. No account
secrets or device-signing credentials are required by this verification workflow.
