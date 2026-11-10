"""Exercise automatic collection through the CLI, including a SIGKILLed runner."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

SCRIPTS = Path(__file__).resolve().parents[1] / 'home/dispatch'


def run(*args, env=None, ok=True):
    p = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True, timeout=30)
    assert not ok or p.returncode == 0, (args, p.stdout, p.stderr)
    return p


with tempfile.TemporaryDirectory(prefix='dispatch-cleanup-', dir='/private/tmp') as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    remote = root / 'remote.git'
    repo.mkdir()
    git = lambda *args, **kw: run('git', '-C', repo, *args, **kw)
    git('init', '-qb', 'main')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    (repo / 'tracked').write_text('base\n')
    git('add', '.'); git('commit', '-qm', 'base')
    run('git', 'init', '--bare', '-q', remote)
    git('remote', 'add', 'origin', remote)
    git('push', '-qu', 'origin', 'main')
    config = root / 'config'
    config.write_text('protected_branches = main release/*\n')
    state = root / 'state'
    wtroot = root / 'worktrees'
    bindir = root / 'bin'; bindir.mkdir()
    rex = bindir / 'rex'
    rex.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['FAKE_REX'])
args = sys.argv[1:]
if args[:2] == ['block', 'ls']:
    closed = (root / 'closed-ids').read_text().splitlines() if (root / 'closed-ids').exists() else []
    ids = [p.read_text().strip() for p in (root / 'evidence').glob('*/result.md.block')]
    print(json.dumps({'blocks': [{'block_id': b} for b in ids if b not in closed]}))
elif args[:2] == ['block', 'close']:
    if (root / 'close-fails').exists(): sys.exit(1)
    (root / 'closed').write_text(' '.join(args))
    with (root / 'closed-ids').open('a') as f: f.write(args[2] + '\\n')
elif args[:2] == ['block', 'inspect']:
    sys.exit(1 if (root / 'closed').exists() else 0)
''')
    rex.chmod(0o755)
    lsof = bindir / 'lsof'
    lsof.write_text('#!/bin/sh\nexit 1\n'); lsof.chmod(0o755)
    env = dict(os.environ, HOME=str(root / 'home'), DISPATCH_CONFIG=str(config), DISPATCH_REPO=str(repo),
               DISPATCH_STATE_DIR=str(state), DISPATCH_EVIDENCE_DIR=str(root / 'evidence'),
               DISPATCH_WORKTREE_ROOT=str(wtroot), PI_SUPERVISOR_STATE_DIR=str(root / 'events'),
               FAKE_REX=str(root), PATH=str(bindir) + os.pathsep + os.environ['PATH'],
               REX_SESSION='session:wrong-parent')
    cli = lambda *args: run(SCRIPTS / 'dispatch', *args, env=env)
    number = 0

    def fixture(name, published=True, phase='ready', owns=True):
        global number
        number += 1
        (root / 'closed').unlink(missing_ok=True)
        wt = wtroot / name
        branch = 'dispatch/' + name.lower()
        git('worktree', 'add', '-qb', branch, wt, 'main')
        if published:
            run('git', '-C', wt, 'push', '-qu', 'origin', 'HEAD')
        d = state / 'workers' / name; d.mkdir(parents=True)
        out = root / 'evidence' / name / 'result.md'; out.parent.mkdir(parents=True)
        Path(str(out) + '.block').write_text('block:' + name)
        reservation = wtroot / '.ports' / str(4000 + number * 10)
        reservation.parent.mkdir(exist_ok=True)
        reservation.write_text(str(d))
        data = dict(name=name, repo=str(repo), branch=branch, worktree=str(wt), owns_local=owns,
                    out=str(out), phase=phase, ports={'base': int(reservation.name)},
                    rex_session='session:original')
        (d / 'state.json').write_text(json.dumps(data))
        return wt, branch, d, out, reservation

    def gone(f, name):
        wt, branch, d, out, reservation = f
        assert not wt.exists() and not d.exists() and not reservation.exists(), name
        assert git('show-ref', '--verify', 'refs/heads/' + branch, ok=False).returncode != 0
        assert list((state / 'archive').glob(name + '-*'))
        assert 'session:original' in (root / 'closed').read_text(), 'close in original Rex session'

    f = fixture('ORPHAN')
    cli('status', '--json')
    gone(f, 'ORPHAN')
    print('PASS: status closes orphan pane and releases worktree, branch, ports; archives evidence')

    for name, edit in [('DIRTY', 'tracked'), ('UNTRACKED', 'untracked'), ('IGNORED', 'cache')]:
        f = fixture(name)
        if name == 'IGNORED':
            (f[0] / '.gitignore').write_text('cache\n')
            run('git', '-C', f[0], 'add', '.gitignore')
            run('git', '-C', f[0], 'commit', '-qm', 'ignore')
            run('git', '-C', f[0], 'push', '-q', 'origin', 'HEAD')
        (f[0] / edit).write_text('uncommitted\n')
        rows = json.loads(cli('status', '--json').stdout)
        assert f[0].exists() and f[2].exists() and f[4].exists()
        assert any(r['name'] == name and r.get('cleanup_blocked') for r in rows), rows
        assert (root / 'closed').exists(), 'close orphan pane even when preserving work'
    print('PASS: tracked, untracked and ignored files block deletion and are reported')

    f = fixture('UNPUSHED')
    (f[0] / 'tracked').write_text('local-only\n')
    run('git', '-C', f[0], 'commit', '-qam', 'local-only')
    assert '未推送' in cli('status').stdout and f[0].exists()
    # --force is not permission to discard unpublished work either.
    p = run(SCRIPTS / 'dispatch', 'clean', 'UNPUSHED', '--force', env=env, ok=False)
    assert p.returncode != 0 and f[0].exists()
    print('PASS: unpushed commits survive automatic and explicit forced collection')

    f = fixture('PUBLISHED')
    (f[0] / 'tracked').write_text('published feature\n')
    run('git', '-C', f[0], 'commit', '-qam', 'published')
    run('git', '-C', f[0], 'push', '-q', 'origin', 'HEAD')
    cli('status'); gone(f, 'PUBLISHED')
    print('PASS: pushed but not locally merged branch can be collected')

    f = fixture('FETCHFAIL')
    git('remote', 'set-url', 'origin', root / 'missing.git')
    cli('status'); assert f[0].exists() and f[2].exists()
    git('remote', 'set-url', 'origin', remote)
    cli('status'); gone(f, 'FETCHFAIL')
    print('PASS: unavailable remote fails closed, retry succeeds')

    f = fixture('CLOSEFAIL')
    (root / 'close-fails').touch()
    cli('status'); assert f[0].exists() and f[2].exists()
    (root / 'close-fails').unlink()
    cli('status'); gone(f, 'CLOSEFAIL')
    print('PASS: failed pane close retains all local resources')

    # The watchdog runs detached from the worker's process group. Killing that
    # whole group must still close the pane without any status/result consumer.
    f = fixture('HARDKILL')
    runner = subprocess.Popen(['sleep', '60'], start_new_session=True)
    (f[2] / 'runner.pid').write_text(str(runner.pid))
    watcher = subprocess.Popen([str(SCRIPTS / 'dispatch'), '_watch', 'HARDKILL'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
    try:
        time.sleep(.2)
        assert watcher.poll() is None
        assert any(r['name'] == 'HARDKILL' and r['phase'] == 'running'
                   for r in json.loads(cli('status', '--json').stdout))
        os.killpg(runner.pid, signal.SIGKILL)
        # Leave runner unreaped briefly: zombies must not hold resources forever.
        assert watcher.wait(timeout=12) == 0, watcher.stderr.read().decode()
        gone(f, 'HARDKILL')
    finally:
        if runner.poll() is None: runner.kill()
        runner.wait()
        if watcher.poll() is None: watcher.kill(); watcher.wait()
    print('PASS: SIGKILLed supervisor group collected without reading result or running status')

    f = fixture('CHILD')
    child = subprocess.Popen(['sleep', '60'], start_new_session=True)
    (f[2] / 'worker.pid').write_text(str(child.pid))
    identity = run('/bin/ps', '-p', child.pid, '-o', 'stat=', '-o', 'lstart=').stdout.split(maxsplit=1)[1].strip()
    (f[2] / 'worker.identity').write_text(identity)
    try:
        cli('status'); gone(f, 'CHILD')
        assert child.wait(timeout=3) == -signal.SIGTERM
    finally:
        if child.poll() is None: child.kill(); child.wait()
    print('PASS: surviving shell supervisor is stopped before checking/removing Git resources')

    f = fixture('REUSEDPID')
    (f[2] / 'runner.pid').write_text(str(os.getpid()))
    (f[2] / 'runner.identity').write_text('different process start time')
    cli('status'); gone(f, 'REUSEDPID')
    print('PASS: reused PID cannot impersonate the original runner')

    f = fixture('LISTENER')
    lsof.write_text('#!/bin/sh\necho 12345\nexit 0\n')
    assert '端口段' in cli('status').stdout
    assert f[0].exists() and f[4].exists()
    lsof.write_text('#!/bin/sh\nexit 1\n')
    cli('status'); gone(f, 'LISTENER')
    print('PASS: live/unknown port listeners retain reservations; never kill unrelated processes')

    f = fixture('DOCTOR')
    report = json.loads(cli('doctor', '--json').stdout)
    assert any(c['area'] == 'cleanup' and 'DOCTOR' in c['text'] for c in report['checks'])
    gone(f, 'DOCTOR')
    print('PASS: doctor reconciles orphans while keeping stdout pure JSON')

    f = fixture('WAIT')
    runner = subprocess.Popen(['sleep', '60'], start_new_session=True)
    (f[2] / 'runner.pid').write_text(str(runner.pid))
    events = root / 'events/events.log'
    cursor = root / 'wait.cursor'; cursor.write_text(str(events.stat().st_size))
    waiter = subprocess.Popen([str(SCRIPTS / 'dispatch'), 'wait', str(cursor)], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(.8)
        runner.kill(); runner.wait()
        stdout, stderr = waiter.communicate(timeout=12)
        assert waiter.returncode == 0 and 'CLEANED WAIT' in stdout, (stdout, stderr)
        gone(f, 'WAIT')
    finally:
        if runner.poll() is None: runner.kill(); runner.wait()
        if waiter.poll() is None: waiter.kill(); waiter.wait()
    print('PASS: wait periodically collects a runner that dies after wait begins')

    # Exercise the real start -> _run -> detached _watch wiring, not just an
    # explicitly launched watcher. Only the Pi payload is replaced.
    copied = root / 'tools/home/dispatch'
    shutil.copytree(SCRIPTS, copied, ignore=shutil.ignore_patterns('__pycache__'))
    payload = copied / 'pi-worker'
    payload.write_text('''#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in --out) out=$2 ;; esac
  shift
done
mkdir -p "$(dirname "$out")"
printf 'block:AUTODONE' > "$out.block"
printf '%s' "$REX_SESSION" > "$out.rex-session"
printf 'synthetic report' > "$out"
''')
    brief = root / 'brief'; brief.write_text('Synthetic worker task')
    startenv = dict(env, REX_SESSION='session:original')
    run(copied / 'dispatch', 'start', 'AUTODONE', brief, '--model', 'fixture/model', env=startenv)
    end = time.monotonic() + 12
    while (state / 'workers/AUTODONE').exists() and time.monotonic() < end:
        time.sleep(.1)
    assert not (state / 'workers/AUTODONE').exists()
    assert not (wtroot / 'AUTODONE').exists()
    archive = next((state / 'archive').glob('AUTODONE-*'))
    assert (archive / 'exit.json').exists() and (archive / 'collector.log').exists()
    print('PASS: real start wires a detached collector; normal completion needs no result reader')

    # Kernel locks, unlike mkdir locks, cannot be stranded by a hard kill.
    lockcode = '''import importlib.machinery, importlib.util, sys, time
loader=importlib.machinery.SourceFileLoader('dispatch', sys.argv[1])
spec=importlib.util.spec_from_loader('dispatch', loader)
d=importlib.util.module_from_spec(spec); loader.exec_module(d)
with d.Lock(d.Path(sys.argv[2])):
 d.Path(sys.argv[3]).touch()
 time.sleep(60)
'''
    ready = root / 'lock-ready'
    locker = subprocess.Popen(['python3', '-B', '-c', lockcode, str(SCRIPTS / 'dispatch'),
                               str(state / '.lock'), str(ready)])
    try:
        end = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < end: time.sleep(.03)
        assert ready.exists()
        locker.kill(); locker.wait()
        f = fixture('LOCKKILL'); cli('status'); gone(f, 'LOCKKILL')
    finally:
        if locker.poll() is None: locker.kill(); locker.wait()
    print('PASS: SIGKILL releases allocator/state locks automatically')

    # Uncertain creation and non-owned/adopted worktrees never get removed.
    for name, changes in [('PENDING', {'local_pending': True}),
                          ('PREPARING', {'phase': 'preparing'}),
                          ('WRONGBRANCH', {'branch': 'dispatch/someone-else'}),
                          ('PROTECTED', {'branch': 'main'}),
                          ('ADOPTED', {'owns_local': False, 'adopted': True}),
                          ('FOREIGN', {'repo': str(root / 'another-repo')})]:
        f = fixture(name)
        data = json.loads((f[2] / 'state.json').read_text()); data.update(changes)
        (f[2] / 'state.json').write_text(json.dumps(data))
        cli('status')
        assert f[0].exists() and f[2].exists(), name
    print('PASS: incomplete, adopted and foreign states are retained')

    # Legacy state records no Rex session. Never assume the caller's session.
    f = fixture('LEGACY')
    data = json.loads((f[2] / 'state.json').read_text()); data.pop('rex_session')
    (f[2] / 'state.json').write_text(json.dumps(data))
    cli('status')
    assert f[0].exists() and f[2].exists()
    print('PASS: unknown pane session is reported, never guessed')
