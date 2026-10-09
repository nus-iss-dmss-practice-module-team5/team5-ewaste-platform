"""Check release ordering and execute the actual workflow gate scripts locally.

Requires Python, PyYAML and jq. No Docker services or cloud credentials are used.
Run: python scripts/test-workflow-gates.py
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class UniqueKeyLoader(yaml.BaseLoader):
    def construct_mapping(self, node, deep=False):
        keys = [self.construct_object(key, deep=deep) for key, _ in node.value]
        if len(keys) != len(set(keys)):
            raise ValueError('Duplicate YAML key in workflow')
        return super().construct_mapping(node, deep=deep)


def workflow(filename):
    # GitHub uses YAML 1.2: retain 'on' as a string, not YAML 1.1's boolean True.
    return yaml.load((ROOT / '.github/workflows' / filename).read_text(), Loader=UniqueKeyLoader)


def run_step(step, cwd=ROOT, **environment):
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / 'output'
        env = {'PATH': os.environ['PATH'], 'GITHUB_OUTPUT': str(output),
               'GITHUB_STEP_SUMMARY': str(Path(directory) / 'summary'), **environment}
        result = subprocess.run(['bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', '-c', step['run']],
                                env=env, cwd=cwd, text=True, capture_output=True, timeout=10)
        return result, output.read_text() if output.exists() else ''


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.release = workflow('cd-pipeline.yml')
        cls.jobs = cls.release['jobs']
        cls.quality = workflow('ci-gate.yml')
        cls.migration = workflow('database-migration.yml')
        cls.infrastructure = workflow('terraform-infra-create.yml')

    def test_no_duplicate_keys_or_independent_release_cascades(self):
        with self.assertRaises(ValueError):
            yaml.load('job:\n  if: success()\n  if: always()\n', Loader=UniqueKeyLoader)
        self.assertEqual(set(self.release['on']), {'push', 'pull_request', 'workflow_dispatch'})
        for child in (self.migration, self.infrastructure):
            self.assertEqual(set(child['on']), {'workflow_call', 'workflow_dispatch'})

    def test_every_pr_and_release_runs_checks_without_path_filters(self):
        for event in ('pull_request', 'push'):
            trigger = self.release['on'][event]
            self.assertEqual(set(trigger['branches']), {'dev', 'main'})
            self.assertNotIn('paths', trigger)
            self.assertNotIn('paths-ignore', trigger)

    def test_suites_are_called_at_same_commit_and_can_run_manually(self):
        for job, filename in [('quality-checks', 'ci-gate.yml'), ('matcher-tests', 'matcher.yml'),
                              ('database-tests', 'database-persistence-tests.yml')]:
            with self.subTest(job=job):
                self.assertEqual(self.jobs[job]['uses'], './.github/workflows/' + filename)
                self.assertNotIn('if', self.jobs[job])
                self.assertEqual(set(workflow(filename)['on']), {'workflow_call', 'workflow_dispatch'})

    def test_required_ci_rejects_each_failed_cancelled_or_skipped_suite(self):
        gate = self.jobs['required-ci']
        suites = {'quality-checks', 'matcher-tests', 'database-tests'}
        self.assertEqual(gate['name'], 'Required CI')
        self.assertEqual(set(gate['needs']), suites)
        self.assertEqual(gate['if'], 'always()')
        results = {name: {'result': 'success'} for name in suites}
        result, _ = run_step(gate['steps'][0], RESULTS=json.dumps(results), TESTED_SHA='test-commit')
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in suites:
            for status in ('failure', 'cancelled', 'skipped'):
                with self.subTest(suite=name, status=status):
                    failed = {**results, name: {'result': status}}
                    result, _ = run_step(gate['steps'][0], RESULTS=json.dumps(failed), TESTED_SHA='test-commit')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('::error::', result.stdout)

    def test_migrations_and_deployment_depend_on_successful_checks(self):
        self.assertIn('required-ci', self.jobs['resolve-environment']['needs'])
        infrastructure = self.jobs['prepare-infrastructure']
        self.assertEqual(infrastructure['uses'], './.github/workflows/terraform-infra-create.yml')
        self.assertEqual(set(infrastructure['needs']), {'required-ci', 'resolve-environment'})
        self.assertEqual(infrastructure['with']['target_env'], '${{ needs.resolve-environment.outputs.environment }}')
        migration = self.jobs['migrate-database']
        self.assertEqual(migration['uses'], './.github/workflows/database-migration.yml')
        self.assertEqual(set(migration['needs']), {'required-ci', 'resolve-environment', 'prepare-infrastructure'})
        self.assertEqual(migration['with']['target_env'], '${{ needs.resolve-environment.outputs.environment }}')
        self.assertEqual(set(self.jobs['deploy-application']['needs']),
                         {'required-ci', 'resolve-environment', 'migrate-database'})
        for name in ('prepare-infrastructure', 'migrate-database', 'deploy-application'):
            self.assertNotIn('if', self.jobs[name])  # Retain GitHub's default success dependency check.
        self.assertIn('deploy-application', self.jobs['smoke-and-audit-verification']['needs'])

    def test_manual_maintenance_shares_release_lock_without_locking_out_caller(self):
        self.assertIn("format('release-{0}'", self.release['concurrency']['group'])
        for job, child, prefix in [('prepare-infrastructure', self.infrastructure, 'terraform'),
                                   ('migrate-database', self.migration, 'liquibase-migration')]:
            self.assertEqual(self.jobs[job]['with']['coordinated_release'], 'true')
            self.assertEqual(child['on']['workflow_call']['inputs']['coordinated_release']['default'], 'false')
            self.assertEqual(child['concurrency']['group'],
                             "${{ inputs.coordinated_release && format('" + prefix +
                             "-{0}', inputs.target_env) || format('release-{0}', inputs.target_env) }}")
            self.assertEqual(child['concurrency']['cancel-in-progress'], 'false')

    def test_dev_and_fork_prs_cannot_enter_deployment_jobs(self):
        self.assertEqual(self.jobs['resolve-environment']['if'],
                         "github.event_name != 'pull_request' || (github.base_ref == 'main' && "
                         'github.event.pull_request.head.repo.full_name == github.repository)')

    def test_release_environment_resolution(self):
        step = self.jobs['resolve-environment']['steps'][0]
        scenarios = [('push', 'refs/heads/dev', '', '', 'dev'),
                     ('push', 'refs/heads/main', '', '', 'prod'),
                     ('pull_request', 'refs/pull/1/merge', 'main', '', 'stg')]
        scenarios += [('workflow_dispatch', 'refs/heads/feature/test', '', target, target)
                      for target in ('dev', 'stg', 'prod')]
        for event, ref, base, target, expected in scenarios:
            with self.subTest(event=event, target=expected):
                result, output = run_step(step, GITHUB_EVENT_NAME=event, GITHUB_REF=ref,
                                          GITHUB_BASE_REF=base, TARGET_ENV_INPUT=target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('environment=' + expected + '\n', output)

    def test_migration_uses_input_environment_and_validates_commands(self):
        self.assertEqual(set(self.migration['on']), {'workflow_call', 'workflow_dispatch'})
        step = self.migration['jobs']['resolve-environment']['steps'][0]
        for target in ('dev', 'stg', 'prod'):
            for command in ('update', 'status', 'validate'):
                with self.subTest(target=target, command=command):
                    result, output = run_step(step, TARGET_ENV_INPUT=target, COMMAND=command)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('environment=' + target + '\n', output)
        for target, command in [('', 'update'), ('other', 'update'), ('dev', 'drop-all')]:
            result, _ = run_step(step, TARGET_ENV_INPUT=target, COMMAND=command)
            self.assertNotEqual(result.returncode, 0)

    def test_rollback_validates_without_applying_new_schema(self):
        self.assertEqual(self.jobs['migrate-database']['with']['command'],
                         "${{ inputs.rollback_tag != '' && 'validate' || 'update' }}")

    def test_infrastructure_input_validation_and_skip(self):
        step = self.infrastructure['jobs']['resolve-environment']['steps'][0]
        for target in ('dev', 'stg', 'prod'):
            for action in ('apply', 'plan', 'skip'):
                with self.subTest(target=target, action=action):
                    result, output = run_step(step, TARGET_ENV_INPUT=target, TERRAFORM_ACTION=action)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('environment=' + target + '\n', output)
        for target, action in [('', 'apply'), ('other', 'apply'), ('dev', 'destroy')]:
            result, _ = run_step(step, TARGET_ENV_INPUT=target, TERRAFORM_ACTION=action)
            self.assertNotEqual(result.returncode, 0)
        provision = self.infrastructure['jobs']['provision-infrastructure']
        self.assertEqual(provision['needs'], ['resolve-environment'])
        self.assertEqual(provision['if'], "inputs.action != 'skip'")

    def test_infrastructure_change_detection_and_rollback(self):
        step = next(item for item in self.jobs['resolve-environment']['steps']
                    if item.get('id') == 'infrastructure')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(['git', '-c', 'user.name=Workflow tests',
                                                '-c', 'user.email=workflow@example.invalid',
                                                '-c', 'commit.gpgsign=false', *args], cwd=root, text=True).strip()

            def commit():
                git('add', '.')
                git('commit', '-qm', 'fixture')
                return git('rev-parse', 'HEAD')

            git('init', '-q')
            (root / 'README.md').write_text('baseline\n')
            base = commit()
            for filename, expected in [('src/backend/main.go', 'false'),
                                       ('terraform/environments/main.tf', 'true'),
                                       ('.github/workflows/terraform-infra-create.yml', 'true'),
                                       ('scripts/verify-evidence-storage.sh', 'true')]:
                path = root / filename
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture\n')
                head = commit()
                for event in ('push', 'pull_request'):
                    result, output = run_step(step, cwd=root, EVENT_NAME=event, BASE_SHA=base,
                                              RELEASE_SHA=head, APPLY_REQUESTED='', ROLLBACK_TAG='')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output, 'apply=' + expected + '\n')
                base = head
            (root / 'terraform/environments/main.tf').unlink()
            head = commit()
            for comparison in (base, '0' * 40, ''):
                result, output = run_step(step, cwd=root, EVENT_NAME='push', BASE_SHA=comparison,
                                          RELEASE_SHA=head, APPLY_REQUESTED='', ROLLBACK_TAG='')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output, 'apply=true\n')
            for requested, rollback, expected in [('false', '', 'false'), ('true', '', 'true'),
                                                   ('false', 'PREVIOUS', 'false'), ('true', 'PREVIOUS', None)]:
                result, output = run_step(step, cwd=root, EVENT_NAME='workflow_dispatch',
                                          BASE_SHA='', RELEASE_SHA=head, APPLY_REQUESTED=requested,
                                          ROLLBACK_TAG=rollback)
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output, 'apply=' + expected + '\n')

    def test_upstream_environment_evidence_has_unique_artifact_names(self):
        names = []
        for child, job in [(self.infrastructure, 'provision-infrastructure'),
                           (self.migration, 'database-migration')]:
            uploads = [step for step in child['jobs'][job]['steps']
                       if step.get('uses', '').startswith('actions/upload-artifact@')]
            self.assertEqual(len(uploads), 1)
            self.assertEqual(uploads[0]['with']['include-hidden-files'], 'true')
            names.append(uploads[0]['with']['name'])
        self.assertEqual(len(set(names)), 2)

    def test_evidence_is_retained_after_test_failure(self):
        for name in ('backend-tests', 'analytics-tests'):
            upload = next(step for step in self.quality['jobs'][name]['steps']
                          if step.get('uses', '').startswith('actions/upload-artifact@'))
            self.assertIn('always()', upload['if'])
        for filename, name in [('matcher.yml', 'matcher'), ('database-persistence-tests.yml', 'persistence')]:
            upload = workflow(filename)['jobs'][name]['steps'][-1]
            self.assertEqual(upload['if'], 'always()')

    def test_manual_release_includes_secret_scan(self):
        scan = next(step for step in self.quality['jobs']['secret-scan']['steps']
                    if step.get('name') == 'Run Gitleaks on Checked Out Source')
        self.assertEqual(scan['if'], "github.event_name != 'pull_request'")


if __name__ == '__main__':
    unittest.main(verbosity=2)
