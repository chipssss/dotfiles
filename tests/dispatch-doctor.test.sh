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
    for tool in ['python3', 'git']:
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
PY
