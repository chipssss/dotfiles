"""Behavior regressions, with external services replaced at the process boundary."""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(os.environ['ROOT']) / 'home/dispatch'
loader = importlib.machinery.SourceFileLoader('dispatch', str(SCRIPTS / 'dispatch'))
spec = importlib.util.spec_from_loader('dispatch', loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)


def result(stdout='', returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, '')


class Security(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dispatch-security-', dir='/private/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config'
        self.config.write_text('protected_branches = stack/*\ntemp_dirs = /private/tmp/ /tmp/\n')
        self.env = patch.dict(os.environ, DISPATCH_CONFIG=str(self.config), PI_SCRIPTS=str(SCRIPTS),
                              PI_APPROVE_CWD=str(self.root), PYTHONDONTWRITEBYTECODE='1')
        self.env.start()
        self.addCleanup(self.env.stop)
        for key, value in dict(ROOT=self.root, REPO=self.root / 'repo', EVIDENCE=self.root / 'evidence',
                               WT_ROOT=self.root / 'wt', CONF={'protected_branches': 'stack/*'}).items():
            p = patch.object(d, key, value)
            p.start()
            self.addCleanup(p.stop)
        self.pr = {'number': 1, 'url': 'https://example.invalid/1', 'headRefOid': 'a' * 40,
                   'baseRefName': 'main', 'baseRefOid': 'b' * 40, 'state': 'OPEN',
                   'headRefName': 'feature/demo', 'isCrossRepository': False}
        self.verdict = {'head': self.pr['headRefOid'], 'base': 'main', 'base_sha': self.pr['baseRefOid'],
                        'author_family': 'openai', 'author_model': 'openai/gpt-6.1-sol',
                        'reviewer': {'family': 'anthropic', 'model': 'claude-opus-4-6', 'runner': 'claude'},
                        'reviewed_at': 'test', 'review': 'test.md', 'verdict': 'APPROVE'}

    def safe(self, command, kind='git push', env=None):
        text = f'Confirm external or irreversible action\nAllow {kind}?\n\n{command}\n↑↓ navigate • enter select\n'
        return subprocess.run(['sh', '-c', '. "$PI_SCRIPTS/approve-rules.sh"; safe_ask "$1"', 'test', text],
                              env=env, capture_output=True).returncode

    def store_verdict(self):
        # Both layouts let the same regression run against the old and new code.
        for directory in [d.review_dir(1, self.pr['headRefOid']),
                          d.review_dir(1, self.pr['headRefOid'], self.pr) if hasattr(d, 'snapshot') else self.root / 'unused']:
            directory.mkdir(parents=True, exist_ok=True)
            (directory / 'verdict.json').write_text(json.dumps(self.verdict))

    def test_P1_1_updated_head_never_authorized_by_script(self):
        self.store_verdict()
        d.CONF['merge_script'] = 'scripts/legacy.mjs'
        class Script:
            stdout = iter([json.dumps({'event': e, 'head': 'c' * 40}) + '\n'
                           for e in ['updated', 'attempt', 'merged']])
            def wait(self): return 0
        with patch.object(d, 'gh', return_value=result(json.dumps(self.pr))), \
                patch.object(d, 'run', return_value=result('// legacy script')), \
                patch.object(d, 'notify'), patch.object(d.subprocess, 'Popen', return_value=Script()) as proc:
            with self.assertRaises(d.Refused):
                d.cmd_merge(argparse.Namespace(pr=1, dry_run=False))
            proc.assert_not_called()  # A log monitor cannot authorize synchronously.

    def test_updated_snapshot_requires_new_approve_before_merge(self):
        self.store_verdict()
        updated = dict(self.pr, headRefOid='c' * 40)
        with patch.object(d, 'gh', return_value=result(json.dumps(updated))), patch.object(d, 'run') as merge:
            with self.assertRaises(d.Refused): d.cmd_merge(argparse.Namespace(pr=1, dry_run=False))
            merge.assert_not_called()
        old = self.pr
        self.pr = updated
        self.verdict = dict(self.verdict, head=updated['headRefOid'])
        self.store_verdict()
        with patch.object(d, 'gh', return_value=result(json.dumps(updated))), \
                patch.object(d, 'run', return_value=result()) as merge, patch.object(d, 'notify'):
            d.cmd_merge(argparse.Namespace(pr=1, dry_run=False))
            self.assertIn(updated['headRefOid'], merge.call_args.args[0])
            self.assertNotIn(old['headRefOid'], merge.call_args.args[0])

    def test_P1_2_entire_command_must_be_safe(self):
        for command in [
            'git push origin feature/demo; git -C . push --force origin main',
            'git push origin feature/demo; rm -rf ~/Documents',
            'git push origin feature/demo; docker compose down --volumes',
            "git push origin feature/demo; psql -h db.example.invalid -c 'DROP DATABASE example'",
            'git push origin feature/demo $(touch /tmp/never-executed)',
            'git push origin feature/demo > /tmp/log',
        ]:
            with self.subTest(command=command): self.assertEqual(self.safe(command), 1)
        for command in ['rm -rf /tmp/safe; /bin/rm -rf ~/Documents',
                        'rm -rf /tmp/safe; docker system prune -af --volumes']:
            with self.subTest(command=command): self.assertEqual(self.safe(command, 'recursive deletion'), 1)
        self.assertEqual(self.safe('git push origin feature/demo'), 0)

    def test_P1_3_missing_broken_empty_and_typo_policy(self):
        bare = dict(os.environ, HOME=str(self.root / 'empty-home'))
        bare.pop('DISPATCH_CONFIG', None)
        self.assertEqual(self.safe('git push origin feature/demo', env=bare), 1)
        default = Path(bare['HOME']) / '.config/dispatch/config'
        default.parent.mkdir(parents=True)
        default.symlink_to(self.root / 'missing')
        self.assertEqual(self.safe('git push origin feature/demo', env=bare), 1)
        for conf in ['', 'protected_branches =\n', 'protected_branch = stack/*\n',
                     'protected_branches = stack/*\n', 'protected_branches = "main\n']:
            self.config.write_text(conf)
            for branch in ['main', 'master', 'refs/heads/main']:
                with self.subTest(conf=conf, branch=branch):
                    self.assertEqual(self.safe('git push origin ' + branch), 1)

    def test_P1_4_symlink_parent_and_escape_then_return(self):
        (self.root / 'link').symlink_to('/Users')
        self.assertEqual(self.safe(f'rm -rf {self.root}/link/example/Documents', 'recursive deletion'), 1)
        # Even a final canonical path back in tmp cannot erase an escaping component.
        (self.root / 'root-link').symlink_to('/')
        self.assertEqual(self.safe(f'rm -rf {self.root}/root-link/private/tmp/safe', 'recursive deletion'), 1)
        (self.root / 'inside').mkdir()
        (self.root / 'safe-link').symlink_to(self.root / 'inside')
        self.assertEqual(self.safe(f'rm -rf {self.root}/safe-link/artifact', 'recursive deletion'), 0)
        self.assertEqual(self.safe('rm -rf /private/tmp', 'recursive deletion'), 1)
        self.config.write_text('protected_branches = stack/*\ntemp_dirs = /tmp/ /private/tmp/ .tmp/\n')
        (self.root / '.tmp').symlink_to('/Users')
        self.assertEqual(self.safe('rm -rf .tmp/example/Documents', 'recursive deletion'), 1)
        self.config.write_text(f'protected_branches = stack/*\ntemp_dirs = {self.root}/link/\n')
        self.assertEqual(self.safe(f'rm -rf {self.root}/link/example/Documents', 'recursive deletion'), 1)

    def test_P1_5_actual_model_not_runner(self):
        models = self.root / 'models'
        models.write_text('interrogate reviewers: pi:anthropic/claude-opus-4-6 high, opus high\n')
        with patch.object(d, 'MODELS', models):
            with self.assertRaises(d.Refused): d.reviewer_for('anthropic')
        same = dict(self.verdict, author_family='anthropic', author_model='anthropic/claude-opus-4-6')
        same['reviewer'] = {'family': 'openai', 'model': 'anthropic/claude-opus-4-6', 'runner': 'pi'}
        self.assertFalse(d.merge_gate(self.pr, same)[0])
        self.assertEqual(d.worker_model(argparse.Namespace(model='anthropic/claude-opus-4-6', thinking='high'))['author_family'], 'anthropic')

    def test_P1_6_head_and_base_snapshot_bound_at_gate_and_cache(self):
        for changed in [dict(self.pr, baseRefName='stack/other'), dict(self.pr, baseRefOid='c' * 40)]:
            with self.subTest(changed=changed): self.assertFalse(d.merge_gate(changed, self.verdict)[0])
        self.store_verdict()
        changed = dict(self.pr, baseRefOid='c' * 40)
        with patch.object(d, 'gh', return_value=result(json.dumps(changed))), \
                patch.object(d, 'reviewer_for', side_effect=d.Refused('new review required')):
            with self.assertRaises(d.Refused):
                d.review(1, 'openai/gpt-6.1-sol', 'brief')

    def test_review_refuses_diff_and_reviewer_snapshot_races(self):
        changed = dict(self.pr, baseRefName='stack/other')
        for phase in ['diff', 'reviewer']:
            views = [self.pr, changed] if phase == 'diff' else [self.pr, self.pr, changed]
            def review_output(reviewer, prompt, out, cwd, number): out.write_text('VERDICT: APPROVE\n')
            with self.subTest(phase=phase), patch.object(d, 'pr_view', side_effect=views), \
                    patch.object(d, 'gh', return_value=result('diff fixture')), \
                    patch.object(d, 'run', return_value=result()), patch.object(d, 'reviewer_for', return_value=self.verdict['reviewer']), \
                    patch.object(d, 'run_reviewer', side_effect=review_output), patch.object(d, 'post_review') as post:
                with self.assertRaises(d.Refused): d.review(1, 'openai/gpt-6.1-sol', 'brief')
                self.assertFalse((d.review_dir(1, self.pr['headRefOid'], self.pr) / 'verdict.json').exists())
                post.assert_not_called()

    def test_explicit_generic_policy_and_unknown_syntax(self):
        self.config.write_text('approval_mode = generic\n')
        self.assertEqual(self.safe('git push origin feature/demo'), 0)
        for branch in ['main', 'master']:
            self.assertEqual(self.safe('git push origin ' + branch), 1)
        for command in ['bash -c "git push origin feature/demo"', 'env git push origin feature/demo',
                        'git -C /tmp push origin feature/demo', 'git push origin feature/demo # comment']:
            self.assertEqual(self.safe(command), 1)

    def test_P2_1_public_payload_includes_metadata_message_body(self):
        script = SCRIPTS / 'public-check'
        repo = self.root / 'public'; repo.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(repo), *args], text=True).strip()
        git('init', '-q'); git('config', 'user.name', 'Fixture')
        git('config', 'user.email', '123+fixture@users.noreply.github.com')
        git('commit', '-qm', 'base', '--allow-empty'); base = git('rev-parse', 'HEAD')
        body = self.root / 'body.md'; body.write_text('Public test PR')
        for label, email, message, text in [
            ('identity', 'fixture@private-host' + '.local', 'safe message', 'safe body'),
            ('message', '123+fixture@users.noreply.github.com', 'path ' + '/'.join(['', 'Users', 'privateuser', 'secret']), 'safe body'),
            ('body', '123+fixture@users.noreply.github.com', 'safe message', 'path ' + '/'.join(['', 'Users', 'privateuser', 'secret'])),
            ('diff', '123+fixture@users.noreply.github.com', 'safe message', 'safe body'),
            ('committer', '123+fixture@users.noreply.github.com', 'safe message', 'safe body'),
            ('checker-source', '123+fixture@users.noreply.github.com', 'safe message', 'safe body'),
            ('clean', '123+fixture@users.noreply.github.com', 'safe message', 'safe body'),
        ]:
            git('checkout', '-q', '--detach', base); git('config', 'user.email', email)
            if label == 'diff':
                (repo / 'artifact').write_text('/'.join(['', 'Users', 'privateuser', 'secret']))
                git('add', 'artifact')
            if label == 'checker-source':
                (repo / 'artifact').write_bytes(script.read_bytes())
                git('add', 'artifact')
            with patch.dict(os.environ, GIT_COMMITTER_EMAIL=('fixture@host' + '.local' if label == 'committer' else email)):
                git('commit', '-qm', message, '--allow-empty')
            body.write_text(text)
            p = subprocess.run(['python3', str(script), '--repo', str(repo), '--base', base, '--pr-body', str(body)], capture_output=True)
            with self.subTest(label=label): self.assertEqual(p.returncode, 0 if label in ('clean', 'checker-source') else 1)

    def test_P2_2_doctor_never_accepts_comment_or_extra_logic(self):
        old = self.root / 'old'; old.mkdir()
        (old / 'approve-rules.sh').write_text('# compare .dotfiles/home/dispatch/approve-rules.sh\necho local-policy\n')
        (old / 'pi-send.sh').write_text('#!/bin/sh\necho custom\nexec sh ~/.dotfiles/home/dispatch/pi-send.sh "$@"\n')
        (old / 'extra-helper').write_text('echo local\n')
        output = io.StringIO()
        with contextlib.redirect_stdout(output): d.compare_dir(d.Doctor(), old)
        text = output.getvalue()
        self.assertNotIn('OK ', text)
        self.assertIn('extra-helper', text)
        self.assertIn('diff -u', text)

    def test_P2_3_merge_is_repo_bound_and_rechecks_snapshot(self):
        self.store_verdict()
        with patch.object(d, 'gh', return_value=result(json.dumps(self.pr))), \
                patch.object(d, 'run', return_value=result()) as run, patch.object(d, 'notify'):
            d.cmd_merge(argparse.Namespace(pr=1, dry_run=False))
            self.assertEqual(run.call_args.kwargs.get('cwd'), d.REPO)
            self.assertIn('--match-head-commit', run.call_args.args[0])
        changed = dict(self.pr, baseRefOid='c' * 40)
        with patch.object(d, 'gh', side_effect=[result(json.dumps(self.pr)), result(json.dumps(changed))]), \
                patch.object(d, 'run') as run:
            with self.assertRaises(d.Refused): d.cmd_merge(argparse.Namespace(pr=1, dry_run=False))
            run.assert_not_called()

    def test_P2_4_vendor_keys_are_redacted(self):
        for prefix in ['sk-proj-', 'sk-ant-api03-', 'sk-']:
            key = prefix + 'SYNTHETIC' * 8
            target = self.root / 'key'; target.write_text(key)
            p = subprocess.run(['sh', str(SCRIPTS / 'secret-scan.sh'), str(target)], capture_output=True, text=True)
            with self.subTest(prefix=prefix):
                self.assertEqual(p.returncode, 1)
                self.assertNotIn(key, p.stdout + p.stderr)
        target.write_text('sk-proj-short sk-ant-api03-short public-model-name')
        self.assertEqual(subprocess.run(['sh', str(SCRIPTS / 'secret-scan.sh'), str(target)], capture_output=True).returncode, 0)

    def start_args(self, **kw):
        brief = self.root / 'brief.md'; brief.write_text('Continue this task')
        return argparse.Namespace(**dict(dict(name='DEMO', brief=str(brief), branch='feature/demo', base='main',
                                             dry_run=False, existing_branch=False, common=None, model=None,
                                             thinking=None, timeout=1, card=None, new_card=None), **kw))

    def test_P2_5_failed_start_has_recoverable_state(self):
        d.CONF['card_command'] = 'fixture-card {title}'
        def run(cmd, **kw):
            if 'show-ref' in cmd: return result(returncode=1)
            if 'ls-remote' in cmd: return result(returncode=0 if cmd[-1] == 'main' else 2)
            if 'rev-parse' in cmd: return result('a' * 40)
            return result()
        with patch.object(d, 'run', side_effect=run), patch.object(d, 'gh', return_value=result()), \
                patch.object(d, 'trust_worktree_root'), patch.object(d, 'allocate_ports', return_value={'base': 3100, 'api': 3101, 'web': 3102, 'last': 3109}), \
                patch.object(d, 'spawn_runner'), patch.object(d, 'create_card', side_effect=OSError('injected card log failure')):
            with self.assertRaises((d.Refused, OSError)):
                d.cmd_start(self.start_args(new_card='demo'))
        state = d.load('DEMO')
        self.assertEqual(state['phase'], 'failed')
        self.assertTrue(state['owns_remote'])
        with patch.object(d, 'find_pr', return_value=None), patch.object(d, 'run', return_value=result()), \
                patch.object(d, 'gh', return_value=result()):
            d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
        self.assertFalse(d.worker_dir('DEMO').exists())

    def test_continuation_existing_branch_and_protected_refusal(self):
        def run(cmd, **kw):
            if 'show-ref' in cmd: return result(returncode=1)
            if 'rev-parse' in cmd: return result('a' * 40)
            return result()
        with patch.object(d, 'run', side_effect=run) as calls, patch.object(d, 'gh', return_value=result(json.dumps(self.pr))) as gh, \
                patch.object(d, 'find_pr', return_value=self.pr), patch.object(d, 'trust_worktree_root'), \
                patch.object(d, 'allocate_ports', return_value={'base': 3100, 'api': 3101, 'web': 3102, 'last': 3109}), \
                patch.object(d, 'spawn_runner'):
            d.cmd_start(self.start_args(existing_branch=True))
            state = d.load('DEMO')
            self.assertEqual(state['pr'], 1)
            self.assertFalse(state['owns_remote'])
            self.assertTrue((d.worker_dir('DEMO') / 'brief.md').is_file())
            self.assertFalse(any('-X' in c.args and 'POST' in c.args for c in gh.call_args_list))
            worktree_calls = [c.args[0] for c in calls.call_args_list if 'worktree' in c.args[0] and 'add' in c.args[0]]
            self.assertTrue(worktree_calls)
        for branch in ['main', 'master', 'stack/shared']:
            with self.subTest(branch=branch), self.assertRaises(d.Refused):
                d.cmd_start(self.start_args(name='BAD', branch=branch, existing_branch=True))

    def test_start_resume_real_git_and_preflight_failure(self):
        bare, repo = self.root / 'remote.git', d.REPO
        def git(path, *args):
            return subprocess.check_output(['git', '-C', str(path), *args], stderr=subprocess.DEVNULL, text=True).strip()
        bare.mkdir(); git(bare, 'init', '--bare', '-q', '-b', 'main')
        repo.mkdir(); git(repo, 'init', '-q', '-b', 'main')
        git(repo, 'config', 'user.name', 'Fixture')
        git(repo, 'config', 'user.email', '123+fixture@users.noreply.github.com')
        git(repo, 'commit', '-qm', 'fixture', '--allow-empty')
        git(repo, 'remote', 'add', 'origin', str(bare)); git(repo, 'push', '-qu', 'origin', 'main')
        head = git(repo, 'rev-parse', 'HEAD')
        git(bare, 'update-ref', 'refs/heads/feature/demo', head)
        pr = dict(self.pr, headRefOid=head)
        ports = {'base': 3100, 'api': 3101, 'web': 3102, 'last': 3109}
        with patch.object(d, 'find_pr', return_value=pr), patch.object(d, 'trust_worktree_root'), \
                patch.object(d, 'allocate_ports', return_value=ports), patch.object(d, 'spawn_runner'), \
                patch.object(d, 'gh') as gh:
            # Dry-run reads the actual remote and writes no state or worktree.
            d.cmd_start(self.start_args(base='origin/main', existing_branch=True, dry_run=True))
            self.assertFalse(d.worker_dir('DEMO').exists()); self.assertFalse((d.WT_ROOT / 'DEMO').exists())
            d.cmd_start(self.start_args(base='origin/main', existing_branch=True))
            wt = d.WT_ROOT / 'DEMO'
            self.assertEqual(git(wt, 'rev-parse', '--abbrev-ref', '@{u}'), 'origin/feature/demo')
            self.assertEqual(git(wt, 'rev-parse', 'HEAD'), head)
            self.assertEqual(d.load('DEMO')['phase'], 'ready')
            self.assertIn('PR #1', (d.worker_dir('DEMO') / 'brief.md').read_text())
            # An active worker name/worktree cannot be reused.
            with self.assertRaises(d.Refused): d.cmd_start(self.start_args(existing_branch=True))
            # Resumed branches belong to the user: clean only removes our checkout.
            d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
            self.assertEqual(git(bare, 'rev-parse', 'refs/heads/feature/demo'), head)
            gh.assert_not_called()
        with patch.object(d, 'allocate_ports', side_effect=d.Refused('ports exhausted')), \
                patch.object(d, 'gh') as gh, patch.object(d, 'trust_worktree_root') as trust:
            with self.assertRaises(d.Refused):
                d.cmd_start(self.start_args(branch='feature/new'))
            self.assertFalse(d.worker_dir('DEMO').exists())
            self.assertFalse((d.WT_ROOT / 'DEMO').exists())
            gh.assert_not_called(); trust.assert_not_called()
        with patch.object(d, 'allocate_ports', return_value=ports):
            with self.assertRaises(d.Refused): d.cmd_start(self.start_args(base='origin/nonexistent', dry_run=True))
        # Fork and wrong-base PRs never reach worktree creation.
        for bad in [dict(pr, isCrossRepository=True), dict(pr, baseRefName='other')]:
            with patch.object(d, 'find_pr', return_value=bad), patch.object(d, 'allocate_ports', return_value=ports):
                with self.assertRaises(d.Refused): d.cmd_start(self.start_args(existing_branch=True))

    def test_pr_comment_context_paths_preserve_spaces_and_globs(self):
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        calls = self.root / 'calls.json'
        (bin_dir / 'rex').write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                                     f'Path({str(calls)!r}).write_text(json.dumps(sys.argv[1:])) if sys.argv[1] == "run" else None\n'
                                     'print("{\\"block_id\\":\\"block:fixture\\"}") if sys.argv[1] == "run" else None\n'
                                     'sys.exit(0 if sys.argv[1] == "run" else 1)\n')
        (bin_dir / 'osascript').write_text('#!/bin/sh\nexit 0\n')
        for file in bin_dir.iterdir(): file.chmod(0o755)
        context = self.root / 'repo with spaces [literal]' / 'AGENTS.md'
        context.parent.mkdir(); context.write_text('Fixture context')
        brief = self.root / 'brief'; brief.write_text('Fixture task')
        env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   PI_COMPLETION_STATE_DIR=str(self.root / 'completion'), PI_SUPERVISOR_STATE_DIR=str(self.root / 'events'))
        p = subprocess.run(['sh', str(SCRIPTS / 'pi-worker'), '--model', 'openai/gpt-6.1-sol',
                            '--cwd', str(context.parent), '--context', str(context), '--context', str(brief),
                            '--prompt-file', str(brief), '--out', str(self.root / 'out.md')], env=env, capture_output=True)
        self.assertEqual(p.returncode, 1)  # Fake pane exits only after successful launch.
        args = json.loads(calls.read_text())
        self.assertIn(str(context), args)
        self.assertEqual(args.count('--append-system-prompt'), 2)
        self.assertIn('--no-context-files', args)

    def test_base_origin_normalization_and_invalid_remote(self):
        for base in ['main', 'origin/main']:
            with self.subTest(base=base), patch.object(d, 'dry_run_start') as dry:
                d.cmd_start(self.start_args(base=base, dry_run=True))
                self.assertEqual(dry.call_args.args[0].base, 'main')
        for base in ['upstream/main', 'refs/heads/main', '../main', 'origin/']:
            with self.subTest(base=base), self.assertRaises(d.Refused):
                d.cmd_start(self.start_args(base=base, dry_run=True))


if __name__ == '__main__':
    unittest.main(verbosity=2)
