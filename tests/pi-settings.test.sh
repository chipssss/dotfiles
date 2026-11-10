#!/usr/bin/env bash
# Settings migration never writes into the repository or loses runtime keys.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
exec python3 -B - <<'PY'
import json
import os
import re
from graphlib import TopologicalSorter
from pathlib import Path
import subprocess
import tempfile

repo = Path(os.environ['ROOT'])
script = repo / 'home/pi-settings-sync.sh'
with tempfile.TemporaryDirectory(prefix='pi-settings-') as tmp:
    root = Path(tmp)
    defaults = root / 'defaults.json'
    defaults.write_text(json.dumps({'packages': ['npm:example'], 'compaction': {'enabled': True}}))
    old = root / 'checkout/home/settings.json'
    old.parent.mkdir(parents=True)
    runtime = {'deviceId': 'synthetic-device', 'lastChangelogVersion': 'synthetic-version',
               'httpProxy': 'http://localhost:1234', 'compaction': {'enabled': False, 'keepRecentTokens': 20000}}
    old.write_text(json.dumps(runtime))
    settings = root / 'agent/settings.json'
    settings.parent.mkdir()
    # Reproduce HM's old generation -> out-of-store link -> repository file.
    generation = root / 'old-home-manager-files/.pi/agent/settings.json'
    generation.parent.mkdir(parents=True)
    generation.symlink_to(old)
    settings.symlink_to(generation)
    def sync(expected=0):
        p = subprocess.run(['sh', str(script), str(defaults), str(settings)], capture_output=True)
        assert (p.returncode != 0 if expected else p.returncode == 0), p.stderr
    # Execute the declared DAG order, including cleanOldGen's unlink behavior.
    nix = (repo / 'home.nix').read_text()
    declaration = re.search(r'syncPiSettings = lib.hm.dag.entry(After|Between)\s*\[([^]]*)\](?:\s*\[([^]]*)\])?', nix)
    kind, first, second = declaration.groups()
    before, after = ([], re.findall(r'"([^"]+)"', first)) if kind == 'After' else (
        re.findall(r'"([^"]+)"', first), re.findall(r'"([^"]+)"', second))
    graph = {'writeBoundary': [], 'linkGeneration': ['writeBoundary'], 'syncPiSettings': after}
    for node in before:
        graph.setdefault(node, []).append('syncPiSettings')
    for node in TopologicalSorter(graph).static_order():
        if node == 'syncPiSettings':
            sync()
        elif node == 'linkGeneration' and settings.is_symlink():
            settings.unlink()  # removed from new generation
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
