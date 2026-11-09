#!/usr/bin/env bash
# Exercise doctor through its CLI in an isolated checkout and HOME.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
exec python3 -B - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix='dispatch-doctor-', dir='/private/tmp') as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    scripts = repo / 'home/dispatch'
    shutil.copytree(Path(os.environ['ROOT']) / 'home/dispatch', scripts,
                    ignore=shutil.ignore_patterns('__pycache__'))
    def git(*args):
        return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL)
    git('init', '-q')
    git('add', '.')
    git('-c', 'user.name=Demo', '-c', 'user.email=demo@example.invalid', 'commit', '-qm', 'fixture')
    home = root / 'home'; home.mkdir()
    config = root / 'config'
    config.write_text('protected_branches = main release/*\n')
    bin_dir = root / 'bin'; bin_dir.mkdir()
    for tool in ['python3', 'git', 'dirname']:
        (bin_dir / tool).symlink_to(shutil.which(tool))
    for tool in ['pi', 'rex', 'lsof', 'osascript', 'sandbox-exec', 'realpath']:
        p = bin_dir / tool
        p.write_text('#!/bin/sh\necho fixture-version\n')
        p.chmod(0o755)
    env = dict(os.environ, HOME=str(home), PATH=str(bin_dir), DISPATCH_CONFIG=str(config))
    def doctor(expected=0):
        p = subprocess.run([str(scripts / 'dispatch'), 'doctor', '--json'],
                           env=env, capture_output=True, text=True)
        assert p.returncode == expected, p.stderr
        # Parsing the entire stdout rejects both prefixes and trailing text.
        report = json.loads(p.stdout)
        assert report['fail_count'] == expected
        return report
    clean = doctor()
    assert clean['dirty'] is False
    assert len(clean['config_sha256']) == 64
    assert all(x['status'] == 'missing' for x in clean['install'].values())
    config.write_text('# presentation changes only\nprotected_branches=main   release/*\nports=3110-3999\n')
    assert doctor()['config_sha256'] == clean['config_sha256']
    config.write_text('protected_branches = main shared/*\n')
    assert doctor()['config_sha256'] != clean['config_sha256']
    (repo / 'untracked').write_text('fixture')
    assert doctor()['dirty'] is True
    (repo / 'untracked').unlink()
    (scripts / 'README.md').write_text('changed fixture')
    assert doctor()['dirty'] is True
    git('checkout', '--', 'home/dispatch/README.md')
    dispatch = home / '.local/bin/dispatch'; dispatch.parent.mkdir(parents=True)
    worker = home / '.claude/bin/pi-worker'; worker.parent.mkdir(parents=True)
    dispatch.symlink_to(scripts / 'dispatch')
    shutil.copyfile(scripts / 'pi-worker', worker)
    installed = doctor()['install']
    assert installed['dispatch']['status'] == 'linked'
    assert installed['pi-worker']['status'] == 'identical-copy'
    worker.write_text('drift')
    assert doctor()['install']['pi-worker']['status'] == 'drifted'
    dispatch.unlink(); dispatch.symlink_to(root / 'missing')
    assert doctor()['install']['dispatch']['status'] == 'drifted'
    (bin_dir / 'lsof').unlink()
    assert doctor(1)['dependencies']['lsof'] is None
    (bin_dir / 'lsof').symlink_to(bin_dir / 'rex')
    config.write_text('protected_branches =\n')
    assert doctor(1)['config_sha256'] is None
    print('PASS: doctor pure JSON, effective config, dirty checkout, installation and failure states')

    # Simulate changing the shared defaults in an isolated checkout. All public
    # consumers must observe the change, not just doctor or one helper.
    defaults_module = scripts / 'dispatchconf.py'
    defaults_module.write_text(defaults_module.read_text() + '''
DEFAULTS = dict(ports='4510-4599', approval_mode='generic', protected_branches='',
                temp_dirs='.tmp/', secret_fixture_passwords='demo-fixture')
''')
    config.write_text('protected_branches = main release/*\n')
    changed = doctor()['config_sha256']
    config.write_text('''protected_branches = main release/*
ports = 4510-4599
approval_mode = generic
temp_dirs = .tmp/
secret_fixture_passwords = demo-fixture
''')
    assert doctor()['config_sha256'] == changed, 'doctor must fingerprint the shared defaults'

    # Even the validation path must use the new port default.
    original_module = defaults_module.read_text()
    defaults_module.write_text(original_module + "\nDEFAULTS['ports'] = '80-89'\n")
    config.write_text('protected_branches = main release/*\n')
    assert doctor(1)['config_sha256'] is None, 'invalid default ports must fail validation'
    defaults_module.write_text(original_module)

    # Local-only CLI probes, no runner, pane, external remote or actual deletion.
    git('branch', '-M', 'main')
    bare = root / 'remote.git'
    subprocess.run(['git', 'init', '--bare', '-q', str(bare)], check=True)
    git('remote', 'add', 'origin', str(bare))
    git('push', '-q', 'origin', 'main')
    git('checkout', '-qb', 'feature/demo')
    env.update(DISPATCH_REPO=str(repo), DISPATCH_STATE_DIR=str(root / 'state'),
               DISPATCH_WORKTREE_ROOT=str(root / 'wt'), PI_SCRIPTS=str(scripts),
               PI_APPROVE_CWD=str(repo))
    (bin_dir / 'lsof').unlink()
    (bin_dir / 'lsof').write_text('#!/bin/sh\nexit 1\n')
    (bin_dir / 'lsof').chmod(0o755)
    brief = root / 'brief'; brief.write_text('Generic fixture task')
    p = subprocess.run([str(scripts / 'dispatch'), 'start', 'DEMO', str(brief), '--dry-run', '--base', 'main'],
                       env=env, capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert 'ports 4510-4519' in p.stdout, 'launcher must allocate from the shared port default'
    assert not (root / 'state').exists() and not (root / 'wt').exists()

    def approve(command, kind, expected):
        text = f'Confirm external or irreversible action\nAllow {kind}?\n\n{command}\n↑↓ navigate\n'
        p = subprocess.run(['/bin/sh', '-c', '. "$PI_SCRIPTS/approve-rules.sh"; safe_ask "$1"', 'test', text],
                           env=env, capture_output=True)
        assert p.returncode == expected, f'approval must use shared defaults: {command}'
    approve(f'rm -rf {root}/artifact', 'recursive deletion', 1)
    approve('rm -rf .tmp/artifact', 'recursive deletion', 0)
    config.write_text('')
    approve('git push origin feature/demo', 'git push', 0)
    config.write_text('approval_mode = strict\n')
    approve('git push origin feature/demo', 'git push', 1)
    config.write_text('')

    artifact = root / 'artifact'
    def scan(password, expected):
        artifact.write_text('redis://' + 'fixture:' + password + '@localhost/test\n')
        p = subprocess.run([str(scripts / 'secret-scan.sh'), str(artifact)], env=env, capture_output=True)
        assert p.returncode == expected, 'scanner must use shared fixture passwords'
    scan('demo-fixture', 0)
    scan('postgres', 1)
    config.write_text('secret_fixture_passwords = override-fixture\n')
    scan('demo-fixture', 1)
    scan('override-fixture', 0)
    # Missing config remains fail-closed for approval, but scanning may use defaults.
    config.unlink()
    approve('git push origin feature/demo', 'git push', 1)
    env.pop('DISPATCH_CONFIG')
    scan('demo-fixture', 0)
    print('PASS: shared defaults drive doctor, validation, launcher, approval and scanner; explicit overrides win')
PY
