#!/bin/bash
# Run on macOS: bash scripts/verify-macos.sh
# Optional: IOS_TEST_DESTINATION='platform=iOS Simulator,id=<UDID>'
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This check requires macOS with Xcode and its iOS/watchOS simulator runtimes.' >&2
    exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for required_tool in xcodegen xcodebuild xcrun python3; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf 'Missing required tool: %s\n' "$required_tool" >&2
        exit 2
    fi
done

if [[ -n "${VERIFY_ARTIFACTS_DIR:-}" ]]; then
    artifact_root="$VERIFY_ARTIFACTS_DIR"
    # Refuse reuse: evidence from an older run must never look current.
    mkdir "$artifact_root"
else
    artifact_root="$(mktemp -d "${TMPDIR:-/tmp}/WatchDayRecorderVerify.XXXXXX")"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'artifacts=%s\n' "$artifact_root" >> "$GITHUB_OUTPUT"
fi
printf 'Verification artifacts: %s\n' "$artifact_root"
trap 'printf "Verification failed. Logs and partial results: %s\n" "$artifact_root" >&2' ERR

{
    xcodebuild -version
    xcodegen --version
    xcrun swift --version
} | tee "$artifact_root/environment.log"

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
    ios_destination="$IOS_TEST_DESTINATION"
else
    simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
candidates = []
for runtime, entries in devices.items():
    version = re.search(r"iOS-(\d+)", runtime)
    if not version or int(version.group(1)) < 17:
        continue
    for entry in entries:
        if entry.get("isAvailable") and "iPhone" in entry.get("name", ""):
            candidates.append(entry)
candidates.sort(key=lambda device: device.get("state") != "Booted")
if not candidates:
    sys.exit("No available iPhone simulator with iOS 17 or later. Install a runtime in Xcode first.")
print(candidates[0]["udid"])
')"
    ios_destination="platform=iOS Simulator,id=$simulator_id"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'ios_simulator=%s\n' "${simulator_id:-}" >> "$GITHUB_OUTPUT"
fi

xcodegen generate --spec "$repo_root/project.yml" | tee "$artifact_root/generation.log"
xcodebuild -list -project "$repo_root/WatchDayRecorder.xcodeproj" | tee "$artifact_root/schemes.log"

xcodebuild -project "$repo_root/WatchDayRecorder.xcodeproj" \
    -scheme WatchDayRecorder -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$artifact_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$artifact_root/iphone-build.log"

xcodebuild -project "$repo_root/WatchDayRecorder.xcodeproj" \
    -scheme WatchDayRecorderWatch -configuration Debug \
    -destination 'generic/platform=watchOS Simulator' \
    -derivedDataPath "$artifact_root/DerivedData" \
    CODE_SIGNING_ALLOWED=NO build 2>&1 | tee "$artifact_root/watch-widget-build.log"

xcodebuild -project "$repo_root/WatchDayRecorder.xcodeproj" \
    -scheme WatchDayRecorder -configuration Debug \
    -destination "$ios_destination" \
    -derivedDataPath "$artifact_root/DerivedData" \
    -resultBundlePath "$artifact_root/UnitTests.xcresult" \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 60 \
    CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$artifact_root/unit-tests.log"

xcrun xcresulttool get test-results summary --path "$artifact_root/UnitTests.xcresult" \
    > "$artifact_root/test-summary.json"
python3 scripts/check-test-summary.py "$artifact_root/test-summary.json" "$repo_root/Tests" \
    | tee "$artifact_root/test-acceptance.log"

printf '\nApple-platform builds and unit tests passed. Results: %s\n' "$artifact_root"
printf '%s\n' 'WatchConnectivity, UI layout, signing/install, and all-day recording still require paired physical-device acceptance.'
