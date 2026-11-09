#!/usr/bin/env bash
# Resident pi-worker supervision, conservative approval and the scanner, with fake Rex.
# Never touches live panes, GitHub or credentials.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PI_SCRIPTS="$ROOT/home/dispatch"
export PI_SCRIPTS ROOT
exec python3 -B - <<'PY'
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

scripts = Path(os.environ['PI_SCRIPTS'])
root = Path(tempfile.mkdtemp(prefix='DISPATCH-test-', dir='/private/tmp'))
passed = 0
config = root / 'dispatch.config'
config.write_text('''protected_branches = main shared/* release/*
temp_dirs = /tmp/ /private/tmp/ .tmp/
secret_pattern.demo token = \\bdemo_[A-Za-z0-9_-]{20,}
secret_fixture_passwords = postgres synthetic
''')
os.environ['DISPATCH_CONFIG'] = str(config)

def check(ok, name):
    global passed
    if not ok:
        raise AssertionError(name)
    passed += 1
    print(f'ok {passed} - {name}', flush=True)

def wait_for(predicate, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.03)
    return False

def ask(kind, command):
    return f'Confirm external or irreversible action\nAllow {kind}?\n\n{command}\n↑↓ navigate • enter select\n'

def repo(path, branch, upstream):
    path.mkdir(parents=True)
    g = lambda *a: subprocess.run(['git', '-C', str(path), *a], check=True, capture_output=True)
    g('init', '-q'); g('config', 'user.email', 't@example.invalid'); g('config', 'user.name', 't')
    g('commit', '-qm', 'fixture', '--allow-empty'); g('checkout', '-qB', branch)
    g('remote', 'add', 'origin', '/private/tmp/DISPATCH-no-network')
    g('update-ref', f'refs/remotes/origin/{upstream}', 'HEAD')
    g('config', f'branch.{branch}.remote', 'origin'); g('config', f'branch.{branch}.merge', f'refs/heads/{upstream}')
    return path

try:
    bin_dir = root / 'bin'; bin_dir.mkdir()
    (bin_dir / 'rex').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
s=Path(os.environ['FAKE_REX_STATE']); args=sys.argv[1:]
with (s/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[0]=='run': print('{"block_id":"block:test"}')
elif args[:2]==['block','inspect']: sys.exit(1 if (s/'closed').exists() else 0)
elif args[:2]==['block','close']: (s/'closed').touch()
elif args[:2]==['block','capture']: print((s/'screen').read_text() if (s/'screen').exists() else '─\\n─')
elif args[:2]==['block','send-key']:
    with (s/'keys').open('a') as f: f.write(args[-1]+'\\n')
elif args[:2]==['block','send']:
    with (s/'sends').open('a') as f: f.write('x\\n')
''')
    (bin_dir / 'sleep').write_text('#!/bin/sh\nexec /bin/sleep 0.03\n')
    (bin_dir / 'osascript').write_text('#!/bin/sh\nexit 0\n')
    for p in bin_dir.iterdir():
        p.chmod(0o755)
    worker = scripts / 'pi-worker'
    feature = repo(root / 'feature repo', 'dispatch/demo', 'dispatch/demo')
    shared = repo(root / 'shared', 'main', 'main')

    def launch(label, cwd=root, attach=None):
        state = root / label; state.mkdir()
        out = state / 'evidence/TEST/result.md'; out.parent.mkdir(parents=True)
        env = dict(os.environ, REX_SESSION='DISPATCH-FAKE', FAKE_REX_STATE=str(state),
                   PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
                   PI_COMPLETION_STATE_DIR=str(state / 'completion'), PI_SUPERVISOR_STATE_DIR=str(state / 'events'))
        prompt = root / 'brief'; prompt.write_text('合成测试')
        cmd = ['sh', str(worker), '--out', str(out), '--label', 'dispatch TEST', '--timeout-min', '1']
        cmd += ['--attach', attach] if attach else ['--model', 'fake/model', '--cwd', str(cwd), '--prompt-file', str(prompt)]
        log = (state / 'output').open('w+')
        proc = subprocess.Popen(cmd, env=env, stdout=log, stderr=log)
        events = state / 'events/events.log'
        read = lambda p: p.read_text() if p.exists() else ''
        return proc, state, out, lambda: read(events), lambda: read(state / 'keys'), log

    def finish(proc, state, out, events, log, name):
        out.write_text('完整报告'); Path(str(out) + '.done').write_text('done')
        check(proc.wait(timeout=8) == 0, name + '：写好报告后退出 0')
        check('DONE TEST' in events() and (state / 'closed').exists(), name + '：DONE 事件并关闭面板')
        log.close()

    proc, state, out, events, keys, log = launch('needs-human')
    try:
        check(wait_for(lambda: (state / 'calls').exists()), '启动面板')
        (state / 'screen').write_text(ask('git push', 'git push origin feature/demo; git -C . push --force origin main'))
        check(wait_for(lambda: 'NEEDS HUMAN TEST' in events()), '危险确认发 NEEDS HUMAN 事件')
        time.sleep(.5)
        check(proc.poll() is None, '需人工后监管不退出')
        check(events().count('NEEDS HUMAN') == 1, '同一确认框只通知一次')
        check(keys() == '', '危险确认不按回车')
        check('复合命令' in Path(str(out) + '.needs-human').read_text(), '.needs-human 写复合命令拒绝原因不写原命令')
        check('origin main' not in events(), '事件不回显复合命令')
        (state / 'screen').write_text('─\n─')
        check(wait_for(lambda: 'RESOLVED TEST' in events()), '人工处理后发 RESOLVED 并继续监管')
        check(not Path(str(out) + '.needs-human').exists(), '处理后删除 .needs-human')
        (state / 'screen').write_text(ask('recursive deletion', 'rm -rf /private/tmp/DISPATCH-x'))
        check(wait_for(lambda: 'enter' in keys()), '之后的安全确认仍自动放行')
        (state / 'screen').write_text('─\n─')
        finish(proc, state, out, events, log, '需人工路径')
    finally:
        if proc.poll() is None: proc.terminate()

    proc, state, out, events, keys, log = launch('empty-report')
    try:
        check(wait_for(lambda: (state / 'calls').exists()), '空报告用例启动')
        for _ in range(4):
            Path(str(out) + '.done').write_text('done')
            wait_for(lambda: not Path(str(out) + '.done').exists())
        check(wait_for(lambda: 'STUCK TEST' in events()), '空报告重写 3 次后发 STUCK')
        time.sleep(.3)
        check(proc.poll() is None, 'STUCK 后监管不退出')
        check(Path(str(out) + '.stuck').exists(), 'STUCK 写 .stuck')
        finish(proc, state, out, events, log, '空报告修复路径')
    finally:
        if proc.poll() is None: proc.terminate()

    for label, cwd, approved in [('cwd-feature', feature, True), ('cwd-main', shared, False)]:
        proc, state, out, events, keys, log = launch(label, cwd=cwd)
        try:
            check(wait_for(lambda: (state / 'calls').exists()), label + ' 启动')
            (state / 'screen').write_text(ask('git push', 'git push'))
            if approved:
                check(wait_for(lambda: 'enter' in keys()), '无 cd 的裸 push 按 pane cwd 判定：功能分支放行')
            else:
                check(wait_for(lambda: 'NEEDS HUMAN' in events()) and keys() == '', '无 cd 的裸 push 按 pane cwd 判定：main 等人工')
            (state / 'screen').write_text('─\n─')
            finish(proc, state, out, events, log, label)
        finally:
            if proc.poll() is None: proc.terminate()

    def safe(command, cwd):
        p = subprocess.run(['sh', '-c', '. "$1/approve-rules.sh"; safe_ask "$2"', 'x', str(scripts), ask('git push', command)],
                           env=dict(os.environ, PI_APPROVE_CWD=str(cwd)), capture_output=True)
        return p.returncode
    fresh = repo(root / 'no upstream', 'dispatch/fresh', 'x'); subprocess.run(['git', '-C', str(fresh), 'config', '--unset', 'branch.dispatch/fresh.merge'], check=True)
    fresh_main = repo(root / 'main no upstream', 'main', 'x'); subprocess.run(['git', '-C', str(fresh_main), 'config', '--unset', 'branch.main.merge'], check=True)
    check(safe('git push -u origin HEAD', fresh) == 0, '无上游的功能分支首推 git push -u origin HEAD 放行')
    check(safe('git push -u origin HEAD', fresh_main) == 1, '无上游的 main 首推 origin HEAD 仍等人工')
    check(safe('git push', fresh) == 1, '无上游的裸 git push 仍等人工')

    proc, state, out, events, keys, log = launch('attach', attach='block:legacy')
    try:
        check(wait_for(lambda: (state / 'calls').exists()), 'attach 启动')
        calls = (state / 'calls').read_text()
        check('"run"' not in calls and 'block:legacy' in calls, 'attach 不新开面板，监管已有面板')
        finish(proc, state, out, events, log, 'attach')
    finally:
        if proc.poll() is None: proc.terminate()

    # Real supervisor transport: rejected tag/config pushes must never send enter.
    subprocess.run(['git', '-C', str(feature), 'tag', 'v9'], check=True)
    for label, command, mapping in [
        ('tag-keyword', 'git push origin tag v9', None),
        ('tag-bare', 'git push origin v9', None),
        ('tag-ref', 'git push origin HEAD:refs/tags/v9', None),
        ('tags-option', 'git push --tags', None),
        ('follow-tags', 'git push --follow-tags', None),
        ('mapped-main', 'git push origin dispatch/demo', 'refs/heads/dispatch/demo:refs/heads/main'),
        ('mapped-wildcard', 'git push', 'refs/heads/*:refs/heads/*'),
    ]:
        if mapping:
            subprocess.run(['git', '-C', str(feature), 'config', 'remote.origin.push', mapping], check=True)
        proc, state, out, events, keys, log = launch(label, cwd=feature)
        try:
            check(wait_for(lambda: (state / 'calls').exists()), label + ' 启动')
            (state / 'screen').write_text(ask('git push', command))
            check(wait_for(lambda: 'NEEDS HUMAN' in events()) and keys() == '', label + ' 不按回车')
            if label == 'tag-keyword':
                reason = Path(str(out) + '.needs-human').read_text()
                check('推送标签' in reason and command not in reason + events(), '推标签通知说明动作且不回显命令')
            (state / 'screen').write_text('─\n─')
            finish(proc, state, out, events, log, label)
        finally:
            if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
            if mapping:
                subprocess.run(['git', '-C', str(feature), 'config', '--unset-all', 'remote.origin.push'], check=True)

    scan_dir = root / 'scan'; scan_dir.mkdir()
    token = 'demo_' + 'FAKE' * 8
    (scan_dir / 'hit.md').write_text(f'令牌 {token}\n')
    (scan_dir / 'fixture.md').write_text('postgresql://postgres:postgres@127.0.0.1:5432/x\n')
    p = subprocess.run([str(scripts / 'secret-scan.sh'), str(scan_dir)], capture_output=True, text=True)
    check(p.returncode == 1 and 'hit.md:1' in p.stdout and token not in p.stdout, '扫描命中只报位置不报值')
    check('fixture.md' not in p.stdout, '回环 fixture 密码不算命中')
    (scan_dir / 'hit.md').unlink()
    check(subprocess.run([str(scripts / 'secret-scan.sh'), str(scan_dir)]).returncode == 0, '干净目录退出 0')
    print(f'PASS: {passed} checks; fake Rex only, no GitHub, no credentials.', flush=True)
finally:
    shutil.rmtree(root)
PY
