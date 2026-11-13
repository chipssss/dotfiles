"""Real Git cleanup regressions; share repository/environment setup with security tests."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest
import dispatch_security as security
SCRIPTS = security.SCRIPTS


class Cleanup(unittest.TestCase):
    git = security.Security.git

    def setUp(self):
        security.Security.setUp(self)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.patch_env = unittest.mock.patch.dict(os.environ, HOME=str(self.root / 'home'),
            PATH=str(self.bin) + os.pathsep + os.environ['PATH'], REX_SESSION='session:wrong-parent',
            PI_SUPERVISOR_STATE_DIR=str(self.root / 'events'), FAKE_REX=str(self.root))
        self.patch_env.start(); self.addCleanup(self.patch_env.stop)
        self.tool('lsof', '#!/bin/sh\nexit 1\n')
        self.tool('rex', '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_REX'])
args = sys.argv[1:]
closed = root / 'closed'
if args[:2] == ['block', 'ls']:
    print(json.dumps({'blocks': [] if closed.exists() else [{'block_id': 'block:fixture'}]}))
elif args[:2] == ['block', 'close']:
    if (root / 'close-fails').exists(): sys.exit(1)
    assert args[-1] == 'session:original'
    closed.touch()
''')

    def tool(self, name, content):
        p = self.bin / name; p.write_text(content); p.chmod(0o755)

    def cli(self, *args, ok=True):
        p = subprocess.run([str(SCRIPTS / 'dispatch'), *args], capture_output=True, text=True, timeout=45)
        self.assertTrue(not ok or p.returncode == 0, p.stderr)
        return p

    def fixture(self, name='DEMO', **changes):
        wt = self.root / 'wt' / name
        self.git(self.repo, 'worktree', 'add', '-qb', 'dispatch/' + name, str(wt), 'main')
        self.git(wt, 'push', '-qu', 'origin', 'HEAD')
        directory = self.root / 'state/workers' / name; directory.mkdir(parents=True)
        out = self.root / 'outputs' / name / 'result.md'; out.parent.mkdir(parents=True)
        Path(str(out) + '.block').write_text('block:fixture')
        data = dict(name=name, repo=str(self.repo), worktree=str(wt), branch='dispatch/' + name,
                    phase='ready', owns_local=True, ports={'base': 4500}, out=str(out), rex_session='session:original')
        data.update(changes)
        (directory / 'state.json').write_text(json.dumps(data))
        reservation = self.root / 'wt/.ports/4500'; reservation.parent.mkdir(exist_ok=True)
        reservation.write_text(str(directory))
        self.wt, self.directory, self.out, self.data = wt, directory, out, data
        return wt

    def gone(self):
        for p in (self.wt, self.directory, self.root / 'wt/.ports/4500'):
            self.assertFalse(p.exists(), p)
        self.assertTrue(list((self.root / 'state/archive').glob(self.data['name'] + '-*')))
        self.assertTrue((self.root / 'closed').exists())
        refs = self.git(self.repo, 'for-each-ref', '--format=%(refname)', 'refs/heads')
        self.assertNotIn('refs/heads/' + self.data['branch'], refs.splitlines())

    def test_local_blocks_and_force(self):
        for name, path, ignored in [('dirty', 'tracked', False), ('untracked', 'new', False), ('ignored', '.env', True)]:
            with self.subTest(name=name):
                wt = self.fixture(name)
                if ignored:
                    (wt / '.gitignore').write_text('.env\n'); self.git(wt, 'add', '.')
                    self.git(wt, 'commit', '-qm', 'ignore'); self.git(wt, 'push', '-q', 'origin', 'HEAD')
                (wt / path).write_text('local data')
                # Security's shared fixture has no tracked files: create a real tracked edit.
                if name == 'dirty':
                    self.git(wt, 'add', '.'); self.git(wt, 'commit', '-qm', 'tracked')
                    (wt / path).write_text('dirty')
                self.assertIn('cleanup_blocked', self.cli('status', '--json').stdout)
                self.assertNotEqual(self.cli('clean', name, '--force', ok=False).returncode, 0)
                self.assertTrue(wt.exists())

    def test_realistic_setup_and_custom_allowlist(self):
        wt = self.fixture()
        (wt / '.gitignore').write_text('node_modules/\ndist/\n.env\n')
        self.git(wt, 'add', '.'); self.git(wt, 'commit', '-qm', 'setup'); self.git(wt, 'push', '-q', 'origin', 'HEAD')
        for path in ('node_modules/pkg/index.js', 'dist/index.js', '.env'):
            p = wt / path; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('synthetic local data')
        self.cli('status'); self.assertTrue(wt.exists(), '.env must block')
        (wt / '.env').unlink()
        self.config.write_text('protected_branches = main\nregenerable_dirs =\n')
        self.cli('status'); self.assertTrue(wt.exists(), 'empty list disables exceptions')
        self.config.write_text('protected_branches = main\nregenerable_dirs = node_modules dist\n')
        # A merged commit remains provably published after its feature ref is deleted.
        self.git(self.repo, 'checkout', '-q', 'main'); self.git(self.repo, 'merge', '--ff-only', 'dispatch/DEMO')
        self.git(self.repo, 'push', '-q', 'origin', 'main'); self.git(self.repo, 'push', '-q', 'origin', '--delete', 'dispatch/DEMO')
        self.cli('status'); self.gone()

    def test_transient_blocks(self):
        self.fixture()
        for tool, content in [('rex', None), ('lsof', '#!/bin/sh\necho 12345\nexit 0\n')]:
            with self.subTest(tool=tool):
                if content: self.tool(tool, content)
                else: (self.root / 'close-fails').touch()
                self.cli('status'); self.assertTrue(self.wt.exists())
                (self.root / 'close-fails').unlink(missing_ok=True)
        self.tool('lsof', '#!/bin/sh\nexit 1\n'); self.cli('status'); self.gone()

    def test_session_fallback_and_unknown(self):
        self.fixture(rex_session='')
        self.cli('status'); self.assertTrue(self.wt.exists())
        Path(str(self.out) + '.rex-session').write_text('session:original')
        self.cli('status'); self.gone()

    def test_uncertain_ownership_and_missing_fields(self):
        cases = [{'local_pending': True}, {'phase': 'preparing'}, {'branch': 'main'},
                 {'branch': 'dispatch/foreign'}, {'owns_local': False}, {'repo': str(self.root / 'foreign')}]
        for i, changes in enumerate(cases): self.fixture('unsafe' + str(i), **changes)
        for field in ('name', 'out', 'branch', 'worktree', 'ports', 'repo', 'owns_local', 'phase'):
            self.fixture('missing' + field)
            self.data.pop(field)
            (self.directory / 'state.json').write_text(json.dumps(self.data))
        for command in [('status', '--json'), ('doctor', '--json'), ('wait',)]:
            result = self.cli(*command)
            text = json.dumps(json.loads(result.stdout), ensure_ascii=False) if '--json' in command else result.stdout
            self.assertIn('状态缺失或无效', text)
        self.assertEqual(len(list((self.root / 'state/workers').iterdir())), len(cases) + 8)

    def test_hardkill_single_collector_and_live_child(self):
        self.fixture()
        runner = subprocess.Popen(['sleep', '60'], start_new_session=True)
        child = subprocess.Popen(['sleep', '60'], start_new_session=True)
        security.d.record_pid(self.directory / 'runner.pid', runner.pid)
        security.d.record_pid(self.directory / 'worker.pid', child.pid)
        watcher = subprocess.Popen([str(SCRIPTS / 'dispatch'), '_watch'], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            time.sleep(.3)
            self.assertIsNone(watcher.poll())
            self.cli('_watch')  # A second collector exits instead of doubling sweeps.
            os.killpg(runner.pid, signal.SIGKILL)
            self.assertEqual(watcher.wait(timeout=40), 0, watcher.stderr.read())
            self.gone(); self.assertEqual(child.wait(timeout=3), -signal.SIGTERM)
        finally:
            for process in (runner, child, watcher):
                if process.poll() is None: process.kill()
                process.wait()
            watcher.stderr.close()

    def test_pid_reuse(self):
        self.fixture()
        (self.directory / 'runner.pid').write_text(str(os.getpid()))
        (self.directory / 'runner.identity').write_text('different process start time')
        self.cli('status'); self.gone()

    def test_real_start_normal_exit(self):
        payload = self.root / 'payload'; payload.write_text('#!/bin/sh\nexit 0\n')
        with unittest.mock.patch.object(security.d, 'PI_WORKER', payload):
            security.d.cmd_start(security.Security.args(self, name='NORMAL'))
        end = time.monotonic() + 40
        while (self.root / 'state/workers/NORMAL').exists() and time.monotonic() < end: time.sleep(.1)
        self.assertFalse((self.root / 'wt/NORMAL').exists())
        archive = next((self.root / 'state/archive').glob('NORMAL-*'))
        self.assertTrue((archive / 'state.json').exists())
        self.assertFalse((self.root / 'outputs/NORMAL/result.md').exists(), 'cleanup needs no report reader')


if __name__ == '__main__':
    unittest.main(verbosity=2)
