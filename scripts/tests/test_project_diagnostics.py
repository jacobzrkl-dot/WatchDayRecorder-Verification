import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('project_diagnostics', Path(__file__).resolve().parents[1] / 'check-project.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticAcceptanceTests(unittest.TestCase):
    def test_remote_tree_checks_source_content_and_mode_but_ignores_readme(self):
        tree = {'truncated': False, 'tree': [
            {'path': 'Sources/App.swift', 'mode': '100644', 'type': 'blob', 'sha': 'abc'},
            {'path': 'README.md', 'mode': '100644', 'type': 'blob', 'sha': 'different'}]}
        self.assertEqual(diagnostics.relevant_tree_entries(tree), {'Sources/App.swift': ('100644', 'blob', 'abc')})

    def test_truncated_remote_tree_cannot_establish_equality(self):
        with self.assertRaises(ValueError):
            diagnostics.relevant_tree_entries({'truncated': True, 'tree': []})

    def test_public_verification_target_does_not_change_source_origin(self):
        self.assertEqual(diagnostics.resolve_ci_repo(None, {'ci_repo': 'owner/public-checks'}, 'git@github.com:owner/private.git'), 'owner/public-checks')
        self.assertEqual(diagnostics.resolve_ci_repo(None, {}, 'https://github.com/owner/public-checks.git'), 'owner/public-checks')

    def test_invalid_verification_target_is_rejected(self):
        with self.assertRaises(ValueError):
            diagnostics.resolve_ci_repo('https://untrusted.example/owner/repo', {}, '')

    def test_billing_failure_without_steps_is_unverified_not_code_failure(self):
        self.assertEqual(diagnostics.failed_run_status([{'steps': []}]), 'UNVERIFIED')

    def test_executed_failed_workflow_remains_failure(self):
        self.assertEqual(diagnostics.failed_run_status([{'steps': [{'name': 'Compile', 'conclusion': 'failure'}]}]), 'FAIL')

    def test_unverified_is_not_success(self):
        self.assertEqual(diagnostics.outcome([{'status': 'PASS'}, {'status': 'UNVERIFIED'}]), 2)

    def test_failure_wins_over_incomplete(self):
        self.assertEqual(diagnostics.outcome([{'status': 'UNVERIFIED'}, {'status': 'FAIL'}]), 1)

    def test_new_failed_matching_run_cannot_be_hidden_by_old_green(self):
        runs = [{'headSha': 'new', 'conclusion': 'failure'}, {'headSha': 'old', 'conclusion': 'success'}]
        self.assertEqual(diagnostics.matching_run(runs, lambda sha: True)['headSha'], 'new')

    def test_unrelated_green_does_not_match_current_inputs(self):
        self.assertIsNone(diagnostics.matching_run([{'headSha': 'other'}], lambda sha: False))
