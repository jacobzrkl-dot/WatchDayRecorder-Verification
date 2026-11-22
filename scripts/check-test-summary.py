"""Fail closed on an empty, skipped or incomplete xcresult test suite."""
import json
from pathlib import Path
import re
import sys


def verify(summary, expected):
    counts = [summary.get(key) for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount")]
    if expected < 1 or any(type(value) is not int or value < 0 for value in counts):
        raise ValueError("Missing/invalid test counts; cannot establish that the suite ran")
    passed, failed, skipped, total = counts
    if failed or skipped or passed != expected or total != passed:
        raise ValueError(f"Expected {expected} passing tests; got passed={passed}, failed={failed}, skipped={skipped}, total={total}")


def main():
    summary_path, tests_root = map(Path, sys.argv[1:])
    expected = sum(len(re.findall(r"^\s*func\s+test\w+\s*\(", path.read_text(encoding="utf-8"), re.MULTILINE))
                   for path in tests_root.rglob("*.swift"))
    verify(json.loads(summary_path.read_text(encoding="utf-8")), expected)
    print(f"Verified all {expected} expected XCTest methods passed, with none skipped")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, TypeError) as error:
        print(f"Test acceptance failed: {error}", file=sys.stderr)
        sys.exit(1)
