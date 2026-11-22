"""Read-only project checks. Exit 0=checked scope passed, 1=failed, 2=incomplete."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RELEVANT = ['Sources', 'Tests', 'project.yml', 'scripts', '.github/workflows']


def run(args, timeout=120):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace', timeout=timeout)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout)[-6000:])
    return result.stdout


def outcome(checks):
    if any(check['status'] == 'FAIL' for check in checks):
        return 1
    return 2 if any(check['status'] == 'UNVERIFIED' for check in checks) else 0


def matching_run(runs, same_inputs):
    # Prefer the newest matching run, even if it failed or is still running.
    # An older green result must not mask a newer failure on identical inputs.
    return next((item for item in runs if same_inputs(item['headSha'])), None)


def failed_run_status(jobs):
    # Billing/capacity failures can finish a run without executing any step.
    # Such a run is not evidence that source compilation/tests failed.
    return 'FAIL' if any(job.get('steps') for job in jobs) else 'UNVERIFIED'


def resolve_ci_repo(explicit, config, origin):
    value = explicit or config.get('ci_repo') or origin.strip()
    for prefix in ('https://github.com/', 'git@github.com:'):
        if value.startswith(prefix):
            value = value[len(prefix):]
    value = value.removesuffix('.git')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', value):
        raise ValueError('Configure --ci-repo owner/repository or a GitHub origin')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cloud', action='store_true', help='also verify GitHub macOS CI matches current inputs')
    parser.add_argument('--ci-repo', help='verification repository; defaults to local config or GitHub origin')
    args = parser.parse_args()
    checks = []

    def check(name, operation):
        try:
            status, detail = operation()
        except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
            status, detail = 'UNVERIFIED', str(error)
        checks.append(dict(name=name, status=status, detail=detail))
        print(f'[{status}] {name}: {detail[:300]}', flush=True)

    def structure():
        required = ['project.yml', 'Sources/Shared', 'Sources/iOSApp', 'Sources/WatchApp',
                    'Sources/WatchWidget', 'Tests', 'scripts/verify-macos.sh', '.github/workflows/apple-platform.yml']
        missing = [path for path in required if not (ROOT / path).exists()]
        return ('FAIL', 'Missing: ' + ', '.join(missing)) if missing else ('PASS', 'Required targets, tests and workflow exist')

    def python_tests():
        result = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-v'],
                                cwd=ROOT, capture_output=True, encoding='utf-8', errors='replace', timeout=120)
        detail = result.stdout + result.stderr
        count = re.search(r'Ran (\d+) tests?', detail)
        passed = result.returncode == 0 and count and int(count[1]) > 0
        return ('PASS' if passed else 'FAIL'), detail

    def syntax():
        config_path = ROOT / '.diagnostics-local.json'
        config = json.loads(config_path.read_text(encoding='utf-8-sig')) if config_path.exists() else {}
        runtime = os.environ.get('WATCHDAY_SWIFT_RUNTIME') or config.get('swift_runtime')
        grammar = os.environ.get('WATCHDAY_SWIFT_GRAMMAR') or config.get('swift_grammar')
        if not runtime or not grammar:
            return 'UNVERIFIED', 'Swift parser not configured; see docs/DIAGNOSTICS.md. This is not a compile pass.'
        try:
            return 'PASS', run(['node', '--liftoff-only', '--single-threaded', 'scripts/check-syntax.cjs', runtime, grammar]).strip()
        except RuntimeError as error:
            return 'FAIL', str(error)

    def cloud():
        config_path = ROOT / '.diagnostics-local.json'
        config = json.loads(config_path.read_text(encoding='utf-8-sig')) if config_path.exists() else {}
        explicit = args.ci_repo or os.environ.get('WATCHDAY_CI_REPO')
        origin = '' if explicit or config.get('ci_repo') else run(['git', 'remote', 'get-url', 'origin'])
        repo = resolve_ci_repo(explicit, config, origin)
        # Include untracked source: git diff alone would silently ignore it.
        changes = run(['git', 'status', '--porcelain', '--untracked-files=all', '--', *RELEVANT]).strip()
        if changes:
            return 'UNVERIFIED', 'Relevant local files differ from HEAD; cloud has not tested this working tree.\n' + changes
        runs = json.loads(run(['gh', 'run', 'list', '--repo', repo, '--workflow', 'apple-platform.yml',
                               '--branch', 'main', '--limit', '30', '--json', 'databaseId,headSha,status,conclusion,url']))

        def same_inputs(sha):
            # Unknown commit is not proof of equivalence. Never fetch/mutate automatically.
            result = subprocess.run(['git', 'diff', '--quiet', sha, 'HEAD', '--', *RELEVANT], cwd=ROOT, capture_output=True)
            return result.returncode == 0

        selected = matching_run(runs, same_inputs)
        if not selected:
            return 'UNVERIFIED', 'No recent cloud run matches the current source/tests/build scripts'
        if selected['status'] != 'completed':
            return 'UNVERIFIED', f"Cloud still {selected['status']}: {selected['url']}"
        if selected['conclusion'] != 'success':
            jobs = json.loads(run(['gh', 'run', 'view', str(selected['databaseId']), '--repo', repo, '--json', 'jobs']))['jobs']
            if failed_run_status(jobs) == 'UNVERIFIED':
                return 'UNVERIFIED', f"Cloud job never executed any steps; inspect Actions billing/capacity annotations: {selected['url']}"
            return 'FAIL', f"Matching cloud run ended {selected['conclusion']}: {selected['url']}"
        return 'PASS', f"Matching macOS build/test/UI workflow: {selected['url']} (commit {selected['headSha']})"

    check('Project structure', structure)
    check('Diagnostic acceptance tests', python_tests)
    check('Swift grammar (not compilation)', syntax)
    check('Apple compilation and XCTest', cloud if args.cloud else lambda: ('UNVERIFIED', 'Use --cloud to verify matching macOS results'))
    report = dict(generated_at=datetime.now(timezone.utc).isoformat(), commit=run(['git', 'rev-parse', 'HEAD']).strip(),
                  checks=checks, swift_test_inventory=sum(len(re.findall(r'^\s*func\s+test\w+\s*\(', p.read_text(encoding='utf-8'), re.M)) for p in (ROOT / 'Tests').rglob('*.swift')),
                  exit_code=outcome(checks), limitations=['Physical Watch recording, paired transfer, all-day endurance and signing are not established by this report.'])
    directory = ROOT / '.diagnostics'
    directory.mkdir(exist_ok=True)
    (directory / 'latest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# Project diagnostics', '', f"Commit: {report['commit']}", f"UTC: {report['generated_at']}", '']
    for item in checks:
        lines += [f"## {item['status']} — {item['name']}", '', '```text', item['detail'], '```', '']
    lines += report['limitations']
    (directory / 'latest.md').write_text('\n'.join(lines), encoding='utf-8')
    print(f'Report: {directory / "latest.md"}\nExit: {report["exit_code"]}')
    return report['exit_code']


if __name__ == '__main__':
    raise SystemExit(main())
