#!/usr/bin/env bash
# Settings migration never writes into the repository or loses runtime keys.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
exec python3 -B - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(os.environ['ROOT'])
script = repo / 'home/pi-settings-sync.sh'
with tempfile.TemporaryDirectory(prefix='pi-settings-') as tmp:
    root = Path(tmp)
    defaults = root / 'defaults.json'
    defaults.write_text(json.dumps({'packages': ['npm:example'], 'compaction': {'enabled': True}}))
    old = root / 'old.json'
    runtime = {'deviceId': 'synthetic-device', 'lastChangelogVersion': 'synthetic-version',
               'httpProxy': 'http://localhost:1234', 'compaction': {'enabled': False, 'keepRecentTokens': 20000}}
    old.write_text(json.dumps(runtime))
    settings = root / 'agent/settings.json'
    settings.parent.mkdir()
    settings.symlink_to(old)
    def sync(expected=0):
        p = subprocess.run(['sh', str(script), str(defaults), str(settings)], capture_output=True)
        assert (p.returncode != 0 if expected else p.returncode == 0), p.stderr
    sync()
    assert not settings.is_symlink()
    actual = json.loads(settings.read_text())
    assert actual['deviceId'] == runtime['deviceId'] and actual['httpProxy'] == runtime['httpProxy']
    assert actual['lastChangelogVersion'] == runtime['lastChangelogVersion']
    assert actual['packages'] == ['npm:example']
    assert actual['compaction'] == {'enabled': True, 'keepRecentTokens': 20000}
    assert json.loads(old.read_text()) == runtime
    assert settings.stat().st_mode & 0o777 == 0o600
    before = settings.read_bytes(); sync(); assert settings.read_bytes() == before
    settings.write_text('{invalid')
    sync(1); assert settings.read_text() == '{invalid'
    settings.unlink(); sync()
    assert json.loads(settings.read_text()) == json.loads(defaults.read_text())
    settings.unlink(); settings.symlink_to(root / 'absent.json')
    sync(1); assert settings.is_symlink()
    authored = json.loads((repo / 'home/.pi/agent/settings.json').read_text())
    assert not {'deviceId', 'lastChangelogVersion', 'httpProxy'} & authored.keys()
    nix = (repo / 'home.nix').read_text()
    assert 'home.file.".pi/agent/settings.json"' not in nix and 'syncPiSettings' in nix
    assert '127.0.0.1:7890' not in (repo / 'home/.zshrc.additions').read_text()
    print('PASS: settings symlink migration, runtime state, deep merge, idempotence, mode 600, malformed/broken input, fresh setup, authored-key isolation')
PY
