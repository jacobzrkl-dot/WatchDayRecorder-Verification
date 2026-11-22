#!/bin/bash
# Capture actual simulator UI, without changing production defaults or recording.
set -euo pipefail
test_ios_id="$1"
artifacts="$2"
iphone_bundle="com.example.WatchDayRecorder"
watch_bundle="com.example.WatchDayRecorder.watchkitapp"

ios_runtime="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for runtime, entries in json.load(sys.stdin)["devices"].items():
    if any(entry["udid"] == sys.argv[1] for entry in entries):
        print(runtime)
        break
else:
    sys.exit("Test simulator runtime could not be located")
' "$test_ios_id")"
iphone_type="$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
for entry in json.load(sys.stdin)["devicetypes"]:
    if entry["name"] == "iPhone 12":
        print(entry["identifier"])
        break
else:
    sys.exit("iPhone 12 simulator type is unavailable")
')"
test_ios_state="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for entries in json.load(sys.stdin)["devices"].values():
    for entry in entries:
        if entry["udid"] == sys.argv[1]:
            print(entry["state"])
            sys.exit(0)
sys.exit("Test simulator state could not be located")
' "$test_ios_id")"
if [[ "$test_ios_state" == "Booted" ]]; then
    xcrun simctl shutdown "$test_ios_id"
elif [[ "$test_ios_state" != "Shutdown" ]]; then
    printf 'Unexpected simulator state: %s\n' "$test_ios_state" >&2
    exit 1
fi
ios_id="$(xcrun simctl create 'WatchDayRecorder iPhone 12 UI' "$iphone_type" "$ios_runtime")"
xcrun simctl bootstatus "$ios_id" -b
xcrun simctl install "$ios_id" "$artifacts/DerivedData/Build/Products/Debug-iphonesimulator/WatchDayRecorder.app"
printf 'Phone UI device: iPhone 12 (%s)\n' "$ios_runtime"
xcrun simctl launch "$ios_id" "$iphone_bundle" -hasSeenRecorderSetup NO
sleep 3
xcrun simctl io "$ios_id" screenshot "$artifacts/iphone-setup.png"
xcrun simctl terminate "$ios_id" "$iphone_bundle"
# NSArgumentDomain overrides the onboarding flag for this launch only.
xcrun simctl launch "$ios_id" "$iphone_bundle" -hasSeenRecorderSetup YES
sleep 3
xcrun simctl io "$ios_id" screenshot "$artifacts/iphone-library.png"
xcrun simctl shutdown "$ios_id"

watch_id="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
candidates = []
for runtime, entries in json.load(sys.stdin)["devices"].items():
    version = re.search(r"watchOS-(\d+)-(\d+)", runtime)
    if not version or int(version[1]) < 10:
        continue
    for entry in entries:
        if entry.get("isAvailable") and "Apple Watch" in entry.get("name", ""):
            width = re.search(r"(\d+)mm", entry["name"])
            candidates.append((int(version[1]), int(version[2]), int(width[1]) if width else 100, entry))
candidates.sort(key=lambda row: (-row[0], -row[1], row[2]))
if not candidates:
    sys.exit("No available watchOS simulator for UI capture")
print("Watch UI device: " + candidates[0][3]["name"], file=sys.stderr)
print(candidates[0][3]["udid"])
')"
xcrun simctl bootstatus "$watch_id" -b
xcrun simctl install "$watch_id" "$artifacts/DerivedData/Build/Products/Debug-watchsimulator/WatchDayRecorderWatch.app"
xcrun simctl launch "$watch_id" "$watch_bundle"
sleep 3
xcrun simctl io "$watch_id" screenshot "$artifacts/watch-ready.png"
printf '%s\n' 'Captured onboarding, iPhone library and Watch ready screen. Audio and transport hardware were not tested.'
