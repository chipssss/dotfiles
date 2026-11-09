"""Push authorization probes. All Git objects/remotes are local, no network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'home/dispatch'


class PushRules(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dispatch-push-', dir='/private/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', '123+fixture@users.noreply.github.com')
        self.git('commit', '-qm', 'fixture', '--allow-empty')
        self.git('checkout', '-qb', 'feature/demo')
        bare = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(bare)], check=True)
        self.git('remote', 'add', 'origin', str(bare))
        self.git('push', '-qu', 'origin', 'main', 'feature/demo')
        self.git('tag', 'v9')
        self.config = self.root / 'config'
        self.config.write_text('protected_branches = shared/*\ntemp_dirs = /tmp/ /private/tmp/\n')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def safe(self, command):
        text = 'Confirm external or irreversible action\nAllow git push?\n\n' + command + '\n↑↓ navigate • enter select\n'
        env = dict(os.environ, PI_SCRIPTS=str(SCRIPTS), PI_APPROVE_CWD=str(self.repo), DISPATCH_CONFIG=str(self.config))
        return subprocess.run(['sh', '-c', '. "$PI_SCRIPTS/approve-rules.sh"; safe_ask "$1"', 'test', text],
                              env=env, capture_output=True).returncode

    def test_tags_always_manual(self):
        for args in ['origin tag v9', 'origin v9', 'origin refs/tags/v9', 'origin HEAD:refs/tags/v9',
                     'origin feature/demo:refs/tags/v9', '--tags', '--follow-tags', 'origin HEAD:v9',
                     'origin HEAD:HEAD', 'origin HEAD:remote-only-tag']:
            with self.subTest(args=args):
                self.assertEqual(self.safe('git push ' + args), 1)

    def test_configured_refspec_cannot_redirect_to_main(self):
        self.git('config', 'remote.origin.push', 'refs/heads/feature/demo:refs/heads/main')
        # Verify Git's actual mapping with --dry-run against the local bare remote.
        mapped = self.git('push', '--dry-run', '--porcelain', 'origin', 'feature/demo')
        self.assertIn('refs/heads/feature/demo:refs/heads/main', mapped)
        for args in ['', 'origin', '-u origin', 'origin feature/demo']:
            with self.subTest(args=args): self.assertEqual(self.safe('git push ' + args), 1)
        self.assertEqual(self.safe('git push origin HEAD:refs/heads/feature/demo'), 0)

    def test_wildcard_matching_and_upstream(self):
        for key, value in [('remote.origin.push', 'refs/heads/*:refs/heads/*'), ('push.default', 'matching'),
                           ('push.default', 'upstream')]:
            self.git('config', key, value)
            if key == 'push.default' and value == 'upstream':
                self.git('config', 'branch.feature/demo.merge', 'refs/heads/main')
            with self.subTest(key=key, value=value): self.assertEqual(self.safe('git push origin'), 1)
            self.git('config', '--unset-all', key)

    def test_safe_effective_modes(self):
        for mode in ['simple', 'upstream', 'current']:
            self.git('config', 'push.default', mode)
            with self.subTest(mode=mode): self.assertEqual(self.safe('git push'), 0)
        self.git('config', 'remote.origin.push', 'refs/heads/feature/demo:refs/heads/feature/other')
        self.assertEqual(self.safe('git push origin'), 0)
        self.assertEqual(self.safe('git push origin feature/demo'), 0)
        self.git('config', 'remote.origin.push', 'refs/heads/feature/demo:refs/tags/v9')
        self.assertEqual(self.safe('git push origin'), 1)

    def test_effective_remote_and_implicit_tags(self):
        self.git('remote', 'add', 'other', str(self.root / 'remote.git'))
        self.git('config', 'remote.other.push', 'refs/heads/feature/demo:refs/heads/main')
        self.git('config', 'remote.pushDefault', 'other')
        self.assertEqual(self.safe('git push'), 1)
        self.git('config', 'branch.feature/demo.pushRemote', 'origin')
        self.git('config', 'push.default', 'current')
        self.assertEqual(self.safe('git push'), 0)
        for key in ['push.followTags', 'remote.origin.mirror']:
            self.git('config', key, 'true')
            with self.subTest(key=key):
                self.assertEqual(self.safe('git push origin HEAD:refs/heads/feature/demo'), 1)
            self.git('config', '--unset', key)
        self.git('config', 'remote.origin.push', 'refs/heads/feature/demo:refs/heads/feature/other')
        self.git('config', '--add', 'remote.origin.push', 'refs/heads/feature/demo:refs/heads/main')
        self.assertEqual(self.safe('git push origin feature/demo'), 1)
        self.assertEqual(self.safe('git push origin'), 1)

    def test_missing_cwd_unknown_source_and_options_manual(self):
        for args in ['origin nonexistent', 'origin nonexistent:feature/new', 'origin refs/notes/demo',
                     'origin HEAD', '--mirror', '--all', 'origin +HEAD:feature/demo']:
            # HEAD by itself is safe, all other cases are unresolvable or unsafe.
            with self.subTest(args=args): self.assertEqual(self.safe('git push ' + args), 0 if args == 'origin HEAD' else 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
