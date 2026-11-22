import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("check_test_summary", Path(__file__).parents[1] / "check-test-summary.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class SummaryGateTests(unittest.TestCase):
    def summary(self, passed=55, failed=0, skipped=0):
        return dict(passedTests=passed, failedTests=failed, skippedTests=skipped,
                    totalTestCount=passed + failed + skipped)

    def test_all_expected_cases_pass(self):
        gate.verify(self.summary(), 55)

    def test_zero_tests_is_failure(self):
        with self.assertRaises(ValueError):
            gate.verify(self.summary(passed=0), 55)

    def test_partial_suite_is_failure(self):
        with self.assertRaises(ValueError):
            gate.verify(self.summary(passed=54), 55)

    def test_skipped_test_is_failure(self):
        with self.assertRaises(ValueError):
            gate.verify(self.summary(passed=54, skipped=1), 55)

    def test_failed_test_is_failure(self):
        with self.assertRaises(ValueError):
            gate.verify(self.summary(passed=54, failed=1), 55)

    def test_missing_or_invalid_counts_are_failure(self):
        for invalid in ({}, self.summary(passed=True), dict(self.summary(), totalTestCount=54)):
            with self.subTest(summary=invalid), self.assertRaises(ValueError):
                gate.verify(invalid, 55)


if __name__ == "__main__":
    unittest.main()
