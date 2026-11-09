"""Generic launcher/security integration tests. No hosting platform or network."""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'home/dispatch'
loader = importlib.machinery.SourceFileLoader('dispatch', str(SCRIPTS / 'dispatch'))
spec = importlib.util.spec_from_loader('dispatch', loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)


class Security(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dispatch-security-', dir='/private/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'config'
        self.config.write_text('protected_branches = shared/*\ntemp_dirs = /private/tmp/ /tmp/\n')
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git(self.repo, 'init', '-q', '-b', 'main')
        self.git(self.repo, 'config', 'user.name', 'Fixture')
        self.git(self.repo, 'config', 'user.email', '123+fixture@users.noreply.github.com')
        self.git(self.repo, 'commit', '-qm', 'fixture', '--allow-empty')
        self.bare = self.root / 'remote.git'
        self.bare.mkdir()
        self.git(self.bare, 'init', '--bare', '-q', '-b', 'main')
        self.git(self.repo, 'remote', 'add', 'origin', str(self.bare))
        self.git(self.repo, 'push', '-qu', 'origin', 'main')
        self.git(self.repo, 'checkout', '-qb', 'feature/demo')
        env = patch.dict(os.environ, DISPATCH_CONFIG=str(self.config), PI_SCRIPTS=str(SCRIPTS),
                         PI_APPROVE_CWD=str(self.repo), DISPATCH_REPO=str(self.repo),
                         DISPATCH_STATE_DIR=str(self.root / 'state'), DISPATCH_EVIDENCE_DIR=str(self.root / 'outputs'),
                         DISPATCH_WORKTREE_ROOT=str(self.root / 'wt'))
        env.start()
        self.addCleanup(env.stop)
        d.configure()
        trust = patch.object(d, 'PI_TRUST', self.root / 'pi' / 'trust.json')
        trust.start()
        self.addCleanup(trust.stop)
        self.brief = self.root / 'brief'
        self.brief.write_text('Generic task')

    def git(self, path, *args):
        return subprocess.check_output(['git', '-C', str(path), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def safe(self, command, kind='git push', env=None):
        text = f'Confirm external or irreversible action\nAllow {kind}?\n\n{command}\n↑↓ navigate • enter select\n'
        return subprocess.run(['sh', '-c', '. "$PI_SCRIPTS/approve-rules.sh"; safe_ask "$1"', 'test', text],
                              env=env, capture_output=True).returncode

    def args(self, **kw):
        return argparse.Namespace(**dict(dict(name='DEMO', brief=str(self.brief), branch='feature/new', base='origin/main',
                                             dry_run=False, existing_branch=False, common=None, model='fixture/model',
                                             thinking='high', timeout=1), **kw))

    def test_entire_compound_must_be_safe(self):
        for command in ['git push origin feature/demo; git -C . push --force origin main',
                        'git push origin feature/demo; rm -rf ~/Documents',
                        'git push origin feature/demo $(touch /tmp/never-executed)',
                        'git push origin feature/demo > /tmp/log',
                        'git push origin feature/demo && git push origin feature/demo',
                        'bash -c "git push origin feature/demo"', 'env git push origin feature/demo']:
            with self.subTest(command=command): self.assertEqual(self.safe(command), 1)
        self.assertEqual(self.safe('git push origin feature/demo'), 0)

    def test_missing_broken_empty_typo_policy(self):
        bare = dict(os.environ, HOME=str(self.root / 'empty-home'))
        bare.pop('DISPATCH_CONFIG', None)
        self.assertEqual(self.safe('git push origin feature/demo', env=bare), 1)
        default = Path(bare['HOME']) / '.config/dispatch/config'
        default.parent.mkdir(parents=True)
        default.symlink_to(self.root / 'missing')
        self.assertEqual(self.safe('git push origin feature/demo', env=bare), 1)
        for conf in ['', 'protected_branches =\n', 'protected_branch = shared/*\n',
                     'protected_branches = shared/*\n', 'protected_branches = "main\n']:
            self.config.write_text(conf)
            for branch in ['main', 'master', 'refs/heads/main']:
                with self.subTest(conf=conf, branch=branch):
                    self.assertEqual(self.safe('git push origin ' + branch), 1)

    def test_explicit_generic_opt_in(self):
        self.config.write_text('approval_mode = generic\n')
        self.assertEqual(self.safe('git push origin feature/demo'), 0)
        self.assertEqual(self.safe('git push origin HEAD:main'), 1)

    def test_symlink_parent_and_escape_then_return(self):
        (self.root / 'link').symlink_to(Path.home())
        self.assertEqual(self.safe(f'rm -rf {self.root}/link/Documents', 'recursive deletion'), 1)
        (self.root / 'root-link').symlink_to('/')
        self.assertEqual(self.safe(f'rm -rf {self.root}/root-link/private/tmp/safe', 'recursive deletion'), 1)
        (self.root / 'inside').mkdir()
        (self.root / 'safe-link').symlink_to(self.root / 'inside')
        self.assertEqual(self.safe(f'rm -rf {self.root}/safe-link/artifact', 'recursive deletion'), 0)
        self.assertEqual(self.safe('rm -rf /private/tmp', 'recursive deletion'), 1)
        self.config.write_text('protected_branches = shared/*\ntemp_dirs = .tmp/\n')
        (self.repo / '.tmp').symlink_to(Path.home())
        self.assertEqual(self.safe('rm -rf .tmp/Documents', 'recursive deletion'), 1)

    def test_project_keys_not_accepted(self):
        for key in ['repo', 'merge_script', 'card_command', 'review_checklist', 'db_wrapper']:
            self.config.write_text(f'protected_branches = main\n{key} = fixture\n')
            with self.subTest(key=key), self.assertRaises(ValueError): d.dispatchconf.load()

    def test_real_git_start_dry_run_resume_clean(self):
        head = self.git(self.repo, 'rev-parse', 'HEAD')
        self.git(self.bare, 'update-ref', 'refs/heads/feature/new', head)
        with patch.object(d, 'spawn_runner') as spawn:
            d.cmd_start(self.args(existing_branch=True, dry_run=True))
            self.assertFalse(d.ROOT.exists())
            self.assertFalse(d.WT_ROOT.exists())
            spawn.assert_not_called()
            d.cmd_start(self.args(existing_branch=True))
            wt = d.WT_ROOT / 'DEMO'
            self.assertEqual(self.git(wt, 'rev-parse', '--abbrev-ref', '@{u}'), 'origin/feature/new')
            self.assertEqual(self.git(wt, 'rev-parse', 'HEAD'), head)
            self.assertTrue(d.load('DEMO')['owns_local'])
            self.assertIn(str(wt), (d.worker_dir('DEMO') / 'brief.md').read_text())
            with self.assertRaises(d.Refused): d.cmd_start(self.args(existing_branch=True))
            d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
            self.assertFalse(wt.exists())
            self.assertFalse(d.worker_dir('DEMO').exists())
            self.assertEqual(self.git(self.bare, 'rev-parse', 'refs/heads/feature/new'), head)
            self.assertEqual(list((d.WT_ROOT / '.ports').iterdir()), [])

    def test_fresh_branch_stays_local_and_ports_reserved(self):
        with patch.object(d, 'spawn_runner'):
            d.cmd_start(self.args())
            first = d.load('DEMO')['ports']['base']
            self.assertIsNone(d.remote_head('feature/new'))
            d.cmd_start(self.args(name='NEXT', branch='feature/next'))
            self.assertNotEqual(d.load('NEXT')['ports']['base'], first)
            self.assertIsNone(d.remote_head('feature/next'))
            d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
            d.cmd_clean(argparse.Namespace(name='NEXT', force=False))

    def test_definite_worktree_failure_is_cleanable(self):
        original = d.run
        def failing(cmd, **kw):
            if 'worktree' in cmd and 'add' in cmd:
                return subprocess.CompletedProcess(cmd, 128, '', 'fixture failure')
            return original(cmd, **kw)
        with patch.object(d, 'run', side_effect=failing), self.assertRaises(d.Refused):
            d.cmd_start(self.args())
        state = d.load('DEMO')
        self.assertEqual(state['phase'], 'failed')
        self.assertFalse(state['local_pending'])
        self.assertFalse(state['owns_local'])
        d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
        self.assertFalse(d.worker_dir('DEMO').exists())

    def test_unmerged_work_requires_force(self):
        with patch.object(d, 'spawn_runner'): d.cmd_start(self.args())
        wt = d.WT_ROOT / 'DEMO'
        (wt / 'task').write_text('work')
        self.git(wt, 'add', 'task')
        self.git(wt, 'commit', '-qm', 'worker change')
        with self.assertRaises(d.Refused): d.cmd_clean(argparse.Namespace(name='DEMO', force=False))
        self.assertTrue(d.worker_dir('DEMO').exists())
        d.cmd_clean(argparse.Namespace(name='DEMO', force=True))
        self.assertFalse(d.worker_dir('DEMO').exists())

    def test_base_normalization_and_protected_branch(self):
        self.assertEqual(d.normalize_base('origin/main'), 'main')
        for base in ['upstream/main', 'refs/heads/main', '../main', 'origin/']:
            with self.subTest(base=base), self.assertRaises(d.Refused): d.normalize_base(base)
        for branch in ['main', 'master', 'shared/demo']:
            with self.subTest(branch=branch), self.assertRaises(d.Refused):
                d.cmd_start(self.args(branch=branch, dry_run=True))

    def test_cwd_worktree_shares_default_repository_state(self):
        # No hard-coded repository config: common git dir is the state identity.
        with patch.dict(os.environ):
            os.environ.pop('DISPATCH_STATE_DIR')
            d.configure()
            root = d.ROOT
            wt = self.root / 'other-worktree'
            self.git(self.repo, 'worktree', 'add', '-qb', 'feature/other', str(wt))
            os.environ['DISPATCH_REPO'] = str(wt)
            d.configure()
            self.assertEqual(root, d.ROOT)

    def test_dotfiles_release_check_uses_its_own_checkout_only(self):
        repo = self.root / 'public-fixture'
        (repo / 'tests').mkdir(parents=True)
        shutil.copy2(SCRIPTS.parent.parent / 'tests/dotfiles-public-check', repo / 'tests/dotfiles-public-check')
        (repo / 'home/dispatch').mkdir(parents=True)
        for name in ['secret-scan.sh', 'dispatchconf.py']:
            shutil.copy2(SCRIPTS / name, repo / 'home/dispatch' / name)
        self.git(repo, 'init', '-q')
        self.git(repo, 'config', 'user.name', 'Fixture')
        self.git(repo, 'config', 'user.email', '123+fixture@users.noreply.github.com')
        self.git(repo, 'add', '.')
        self.git(repo, 'commit', '-qm', 'base')
        base = self.git(repo, 'rev-parse', 'HEAD')
        for label in ['clean', 'identity', 'message', 'diff', 'committer']:
            self.git(repo, 'checkout', '-q', '--detach', base)
            email = 'fixture@example.invalid' if label == 'identity' else '123+fixture@users.noreply.github.com'
            self.git(repo, 'config', 'user.email', email)
            if label == 'diff':
                (repo / 'artifact').write_text('ghp_' + 'SYNTHETIC' * 6)
                self.git(repo, 'add', 'artifact')
            message = 'fixture ' + '/'.join(['', 'Users', 'fixture', 'private']) if label == 'message' else 'safe fixture'
            with patch.dict(os.environ, GIT_COMMITTER_EMAIL='fixture@example.invalid' if label == 'committer' else email):
                self.git(repo, 'commit', '-qm', message, '--allow-empty')
            p = subprocess.run(['python3', '-B', str(repo / 'tests/dotfiles-public-check'), '--base', base], capture_output=True)
            with self.subTest(label=label): self.assertEqual(p.returncode, 0 if label == 'clean' else 1)

    def test_doctor_never_accepts_comment_or_extra_logic(self):
        old = self.root / 'old'
        old.mkdir()
        (old / 'approve-rules.sh').write_text('# home/dispatch/approve-rules.sh\necho local-policy\n')
        (old / 'extra-helper').write_text('echo local\n')
        output = io.StringIO()
        with contextlib.redirect_stdout(output): d.compare_dir(d.Doctor(), old)
        self.assertNotIn('OK ', output.getvalue())
        self.assertIn('extra-helper', output.getvalue())
        self.assertIn('diff -u', output.getvalue())


if __name__ == '__main__':
    unittest.main(verbosity=2)
