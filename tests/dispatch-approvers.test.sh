#!/usr/bin/env bash
# Approval rules, completion contract and the pi-worker supervisor with a fake Rex transport; never touches live panes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PI_SCRIPTS="$ROOT/home/dispatch"
export PI_SCRIPTS ROOT
exec python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

scripts = Path(os.environ['PI_SCRIPTS'])
root = Path(tempfile.mkdtemp(prefix='DISPATCH-approval-test-', dir='/private/tmp'))
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

def git(*args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.DEVNULL, text=True).strip()

repo = root / 'repo with spaces'
repo.mkdir()
git('init', '-q')
git('config', 'user.email', 'demo@example.invalid')
git('config', 'user.name', 'Demo fixture')
git('commit', '-qm', 'fixture', '--allow-empty')
git('checkout', '-qb', 'feature/demo')
git('remote', 'add', 'origin', '/private/tmp/DISPATCH-no-network')
git('update-ref', 'refs/remotes/origin/feature/demo', 'HEAD')
git('branch', '--set-upstream-to=origin/feature/demo')

def ask(kind, command, menu=True):
    return f'Confirm external or irreversible action\nAllow {kind}?\n\n{command}\n' + ('↑↓ navigate • enter select\n' if menu else '')

def approve(name, command, expected=0, kind='git push', menu=True, prefix=''):
    p = subprocess.run(['sh', '-c', '. "$1/approve-rules.sh"; safe_ask "$2"; r=$?; printf "%s" "$APPROVAL_REASON"; exit "$r"',
                        'test', str(scripts), prefix + ask(kind, command, menu)], capture_output=True, text=True)
    check(p.returncode == expected, f'{name}: status={p.returncode} expected={expected}, reason={p.stdout}')
    return p

try:
    for name, cmd, code in [
        ('双空格安全 rm', 'rm -rf  /private/tmp/DISPATCH-safe', 0),
        ('复合 rm 交人工', 'rm -rf /tmp/a && rm -rf ../tmp-demo', 1),
        ('双空格相邻仓库 rm', 'rm -rf  ../project', 1),
        ('全部 rm 目标都检查', 'rm -rf /tmp/a ../project', 1),
        ('临时目录穿越', 'rm -rf /private/tmp/../../Users', 1),
        ('容器删除等人工', 'docker rm -fv demo-cache', 1),
        ('多个容器等人工', 'docker rm -fv demo-cache demo-web', 1),
        ('容器加目录交人工', 'docker rm -fv demo-cache; rm -rf /tmp/a', 1),
        ('容器加相邻仓库', 'docker rm -fv demo-cache; rm -rf ../project', 1),
    ]:
        approve(name, cmd, code, 'recursive deletion')
    for name, cmd, code in [
        ('merge 后推功能分支交人工', 'git merge origin/shared/demo && git push origin feature/demo', 1),
        ('受保护 refspec', 'git push origin HEAD:refs/heads/shared/demo', 1),
        ('force', 'git push --force origin feature/demo', 1),
        ('force lease', 'git push --force-with-lease origin feature/demo', 1),
        ('短 force', 'git push -f origin feature/demo', 1),
        ('plus refspec', 'git push origin +HEAD:feature/demo', 1),
        ('delete', 'git push origin --delete feature/demo', 1),
        ('origin main', 'git push origin main', 1),
        (':main 删除', 'git push origin :main', 1),
        ('shared 分支', 'git push origin HEAD:shared/x', 1),
        ('release 分支', 'git push origin HEAD:release/v1', 1),
        ('完整 refs main', 'git push origin HEAD:refs/heads/main', 1),
        ('多次 push 逐条检查', 'git push origin feature/demo; git push origin main', 1),
        ('没有 cd 的裸 push', 'git push', 1),
        ('只有 cd 路径文本', 'echo cd /tmp; git push', 1),
    ]:
        approve(name, cmd, code)
    cd = f'cd "{repo}" && '
    for suffix in ['', '; echo complete', ' && echo complete', '\necho complete', ' -u']:
        approve('cd 复合 push 交人工 ' + repr(suffix), cd + 'git push' + suffix, 1)
    approve('软换行不能隐藏 main 目标', cd + 'git push\norigin main', 1)
    approve('软换行不能隐藏共享目标', cd + 'git push origin\nHEAD:shared/demo', 1)
    approve('软换行不能隐藏强推', cd + 'git push\n--force origin feature/demo', 1)
    approve('换行和重定向交人工', 'git\n push origin feature/demo > /tmp/push.log 2>&1 &', 1)
    approve('git 与 push 之间软换行仍拦 main', 'git\npush origin main', 1)
    approve('半渲染对话', 'git push origin main', 2, menu=False)
    approve('半渲染 rm 对话', 'cp /p', 2, 'recursive deletion', menu=False)
    approve('命令中的 navigate 不算菜单', 'git push origin feature/navigate', 2, menu=False)
    approve('只看最后一个对话', 'git push origin main', 1,
            prefix=ask('git push', 'git push origin feature/old'))
    approve('最新半渲染不沿用旧菜单', 'git push origin main', 2, menu=False,
            prefix=ask('git push', 'git push origin feature/old'))
    for cmd in ['docker rm demo-cache', 'psql --version', 'scripts/demo.sh', 'echo hello']:
        p = approve('任意非 push/rm 命令转人工', cmd, 1)
        check(p.stdout == '此操作不在简单命令自动审批范围内', '通用拒绝不回显原命令')
    for cmd in ["docker ps --format '{{.Names}}'", 'docker ps -a', 'pgrep -x node',
                '/usr/bin/pgrep -x node', 'echo ps', "echo 'pgrep -f node'",
                '/private/tmp/ps', '/tmp/ps-helper', 'psql --version']:
        p = approve('非进程命令行查询使用通用理由', cmd, 1)
        check(p.stdout == '此操作不在简单命令自动审批范围内', '不把参数或 PID-only 查询误报为命令行查询')
    os.environ['PI_APPROVE_CWD'] = str(repo)
    git('branch', 'feature/ps-fix')
    for cmd in ['git push origin feature/ps-fix', 'git push origin HEAD:refs/heads/fix/ps']:
        approve('含 ps 的功能分支放行', cmd)
    for target in ['ps', 'apps.ps']:
        approve('含 ps 的临时路径放行', f'rm -rf "{root / target}"', kind='recursive deletion')
    del os.environ['PI_APPROVE_CWD']
    for cmd in ['ps aux', 'ps -ef', '/bin/ps -eo args', 'pgrep -fl node',
                'pgrep -af node', 'pgrep --full node', 'pgrep -f node',
                'pgrep -a node', 'pgrep -l node', 'pgrep --list-name node',
                '/usr/bin/pgrep -f node', 'pgrep --list-full node',
                "bash -c 'pgrep -fl node'", "'pgrep' '-af' node"]:
        p = approve('完整命令行查询拒绝', cmd, 1)
        if cmd.startswith('bash '):
            check('此操作不在简单命令自动审批范围内' in p.stdout, '嵌套 shell 转人工且不猜测内部命令')
        else:
            check('进程命令行' in p.stdout, '进程查询拒绝不回显原命令')
        p = approve('含查询的复合命令拒绝', cmd + '; git push origin feature/demo', 1)
        check('复合命令' in p.stdout, '复合命令使用保守通用理由')
    approve('PID-only pgrep 复合命令交人工', 'pgrep -x node; git push origin feature/demo', 1)
    approve('端口查询复合命令交人工', 'lsof -nP -iTCP:3001 -sTCP:LISTEN -t; git push origin feature/demo', 1)
    for branch in ['shared/x', 'release/v1', 'main']:
        git('checkout', '-qB', branch)
        git('config', f'branch.{branch}.remote', 'origin')
        git('config', f'branch.{branch}.merge', 'refs/heads/feature/demo')
        approve('当前共享分支裸 push ' + branch, cd + 'git push', 1)
    git('checkout', '-q', 'feature/demo')
    for branch in ['main', 'shared/x', 'release/v1']:
        git('update-ref', 'refs/remotes/origin/' + branch, 'HEAD')
        git('config', 'branch.feature/demo.merge', 'refs/heads/' + branch)
        approve('上游共享分支裸 push ' + branch, cd + 'git push', 1)
    git('config', '--unset', 'branch.feature/demo.merge')
    approve('无上游裸 push', cd + 'git push', 1)

    # Missing default and explicit config both fail closed; generic policy is explicit opt-in.
    def approve_with(name, command, expected, kind, env):
        p = subprocess.run(['sh', '-c', '. "$1/approve-rules.sh"; safe_ask "$2"; r=$?; printf "%s" "$APPROVAL_REASON"; exit "$r"',
                            'test', str(scripts), ask(kind, command)], capture_output=True, text=True, env=env)
        check(p.returncode == expected, f'{name}: status={p.returncode} expected={expected}, reason={p.stdout}')
        return p
    bare = {k: v for k, v in os.environ.items() if k != 'DISPATCH_CONFIG'}
    bare['HOME'] = str(root / 'empty home')
    approve_with('无配置时 main 仍受保护', 'git push origin main', 1, 'git push', bare)
    approve_with('无配置时功能分支也等人工', 'git push origin HEAD:refs/heads/feature/demo', 1, 'git push', bare)
    approve_with('无配置时容器不自动删除', 'docker rm -fv demo-cache', 1, 'recursive deletion', bare)
    p = approve_with('无配置时任意命令等人工', 'echo hello', 1, 'git push', bare)
    check('人工确认' in p.stdout, '无配置时提示需要人工确认')
    approve_with('配置文件缺失时全部等人工', 'git push origin feature/demo', 1, 'git push',
                 dict(os.environ, DISPATCH_CONFIG=str(root / 'missing.config')))

    # Test actual CLI loops; Rex is the sole external transport stub.
    bin_dir = root / 'bin'; bin_dir.mkdir()
    (bin_dir / 'rex').write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
s=Path(os.environ['FAKE_REX_STATE']); args=sys.argv[1:]
with (s/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args[0]=='run': print('{"block_id":"block:test"}')
elif args[:2]==['block','list']:
    name=(s/'name').read_text() if (s/'name').exists() else 'TEST'
    print(json.dumps([] if (s/'closed').exists() else [{'block_id':'block:'+name.lower(),'label':'pi '+name}]))
elif args[:2]==['block','close']: (s/'closed').touch()
elif args[:2]==['block','capture']:
    print((s/'screen').read_text() if (s/'screen').exists() else '─\\n─')
elif args[:2]==['block','send']:
    count=int((s/'sends').read_text())+1 if (s/'sends').exists() else 1
    (s/'sends').write_text(str(count))
    out=Path(os.environ['FAKE_OUT'])
    if os.environ.get('FAKE_REPAIR')=='1': out.write_text('完整的合成报告')
    if os.environ.get('FAKE_NO_DONE')!='1': Path(str(out)+'.done').write_text('done')
''')
    (bin_dir / 'sleep').write_text('#!/bin/sh\nexec /bin/sleep 0.03\n')
    (bin_dir / 'osascript').write_text('#!/bin/sh\nexit 0\n')
    for p in bin_dir.iterdir(): p.chmod(0o755)
    prompt = root/'brief'; prompt.write_text('合成测试，不启动真实 Pi')

    def environment(label):
        state=root/label; state.mkdir()
        evidence=state/'evidence'; (evidence/'TEST').mkdir(parents=True)
        out=evidence/'TEST/custom report.md'; out.write_text('')
        env=dict(os.environ, REX_SESSION='DISPATCH-FAKE', FAKE_REX_STATE=str(state), FAKE_OUT=str(out),
                 PATH=str(bin_dir)+os.pathsep+os.environ['PATH'], PI_EVIDENCE_DIR=str(evidence),
                 PI_COMPLETION_STATE_DIR=str(state/'completion'), PI_SUPERVISOR_STATE_DIR=str(state/'supervisor'),
                 PI_SUPERVISOR_POLL_SEC='0.03', PI_WAIT_POLL_SEC='0.03')
        return state,out,env

    def wait_for(predicate, timeout=8):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            if predicate(): return True
            time.sleep(.03)
        return False

    worker = scripts / 'pi-worker'
    def start_worker(state, out, env):
        log=(state/'output').open('w+')
        cmd=['sh', str(worker), '--model','fake/model','--cwd',str(root),'--prompt-file',str(prompt),
             '--out',str(out),'--label','pi TEST','--timeout-min','1']
        return subprocess.Popen(cmd,env=env,stdout=log,stderr=log), log
    events_of=lambda state: (state/'supervisor/events.log').read_text() if (state/'supervisor/events.log').exists() else ''

    state,out,env=environment('worker')
    proc,log=start_worker(state,out,env)
    try:
        # pi-worker removes stale output at launch; deliver marker after its fake pane exists.
        check(wait_for(lambda: (state/'calls').exists()), 'worker 启动')
        Path(str(out)+'.done').write_text('done')
        check(wait_for(lambda: (state/'sends').exists() and int((state/'sends').read_text())==3), 'worker 空报告最多重写 3 次')
        check(wait_for(lambda: 'STUCK TEST' in events_of(state)), 'worker 第 4 次空报告发 STUCK 事件')
        sends = [json.loads(line) for line in (state/'calls').read_text().splitlines()]
        repairs = [call[-1] for call in sends if call[:2] == ['block', 'send']]
        check(len(repairs) == 3 and all(out.name in text and 'result.md' not in text for text in repairs),
              '重写消息使用 --out 实际文件名，支持空格')
        check(out.name in events_of(state) and 'result.md' not in events_of(state), 'STUCK 提示使用 --out 实际文件名')
        check('DONE' not in events_of(state) and not (state/'closed').exists(), 'worker 空报告不发 DONE 不关闭面板')
        check(not Path(str(out)+'.done').exists(), 'worker 空 done 被删除')
        check(proc.poll() is None, 'worker 在 STUCK 后继续监管')
        first=subprocess.run(['sh',str(scripts/'pi-events-wait.sh')],env=env,capture_output=True,text=True,timeout=3)
        check(first.returncode==0 and 'STUCK TEST' in first.stdout, '一次性 waiter 回放未读事件')
        waitlog=(state/'waiter').open('w+')
        waiter=subprocess.Popen(['sh',str(scripts/'pi-events-wait.sh')],env=env,stdout=waitlog,stderr=waitlog)
        try:
            time.sleep(.2)
            check(waiter.poll() is None, '重启 waiter 不重复通知已读事件')
            (state/'screen').write_text(ask('git push', 'echo "$DEMO_INPUT"; git push origin feature/demo'))
            waiter.wait(timeout=5); waitlog.flush()
            notified=(state/'waiter').read_text()
            check('NEEDS HUMAN TEST' in notified and '复合命令' in notified and 'DONE' not in notified, 'pi-worker 拒绝复合命令，新事件单独通知后 waiter 退出')
            check('DEMO_INPUT' not in notified+(state/'output').read_text(), 'NEEDS HUMAN 不回显原命令')
            (state/'screen').write_text('spinner changed\n' + (state/'screen').read_text())
            time.sleep(.4)
            check(events_of(state).count('NEEDS HUMAN')==1, '动画变化不会重复报告同一确认')
            check(proc.poll() is None and not (state/'closed').exists(), 'pi-worker 在 NEEDS HUMAN 后继续监管、不关闭面板')
        finally:
            if waiter.poll() is None: waiter.terminate(); waiter.wait(timeout=3)
            waitlog.close()
        (state/'screen').write_text('─\n─')
        out.write_text('完整报告'); Path(str(out)+'.done').write_text('done')
        check(proc.wait(timeout=8)==0 and 'DONE TEST' in events_of(state), 'worker 人工修复非空后 DONE 退出 0')
    finally:
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
        log.close()

    state,out,env=environment('worker-repair')
    env['FAKE_REPAIR']='1'
    proc,log=start_worker(state,out,env)
    try:
        check(wait_for(lambda: (state/'calls').exists()), 'worker 修复路径启动')
        Path(str(out)+'.done').write_text('done')
        check(proc.wait(timeout=8)==0, 'worker 重写非空后成功退出')
        check(out.stat().st_size>0 and (state/'closed').exists(), 'worker 非空独立回读且关闭面板')
        check((state/'sends').read_text()=='1', 'worker 修复成功后不重复催写')
    finally:
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=3)
        log.close()

    for label, secret in [
        ('private-key', '-----BEGIN ' + 'OPENSSH PRIVATE KEY-----'),
        ('private-key-rsa', '-----BEGIN ' + 'RSA PRIVATE KEY-----'),
        ('private-key-pkcs8', '-----BEGIN ' + 'PRIVATE KEY-----'),
        ('private-key-encrypted', '-----BEGIN ' + 'ENCRYPTED PRIVATE KEY-----'),
        ('private-key-pgp', '-----BEGIN ' + 'PGP PRIVATE KEY BLOCK-----'),
        ('github-token', 'ghp_' + 'syntheticNotReal' * 3),
        ('config-pattern', 'demo_' + 'synthetic-not-real' * 2),
        ('redis-password-only', 'redis://' + ':not-a-real-password@cache.example.com:6379/0'),
        ('redis-url', 'redis://' + 'fixture:not-a-real-password@localhost.example/test'),
        ('mysql-url', 'mysql://' + 'fixture:not-a-real-password@127.0.0.1.evil.com/test'),
        ('generic-url', 'demo+tcp://' + 'fixture:not-a-real-password@[2001:db8::1]/test'),
        ('uppercase-url', 'HTTPS://' + 'fixture:not-a-real-password@example.com/test'),
        ('url-query', 'https://' + 'fixture:not-a-real-password@example.com?fixture.invalid'),
        ('url-fragment', 'https://' + 'fixture:not-a-real-password@example.com#fixture.invalid'),
        ('database-url', 'postgres://' + 'fixture:not-a-real-password@db.example.com/test'),
        ('database-url-long', 'postgresql://' + 'fixture:not-a-real-password@db.example.com/test'),
        ('jwt', 'eyJhbGciOiJIUzI1NiJ9' + '.eyJzdWIiOiJmaXh0dXJlIn0' + '.c3ludGhldGljLXNpZ25hdHVyZQ'),
        ('jwt-whitespace', 'eyAiYWxnIjogIkhTMjU2IiB9' + '.eyAic3ViIjogImZpeHR1cmUiIH0' + '.c3ludGhldGljLXNpZ25hdHVyZQ'),
    ]:
        state,out,env=environment('secret-'+label)
        out.write_text('非空安全报告')
        nested=out.parent/'nested'; nested.mkdir()
        artifact=nested/'artifact.bin'; artifact.write_bytes(b'\x00'+secret.encode())
        scan=subprocess.run(['sh', str(scripts/'secret-scan.sh'), str(out.parent)], capture_output=True, text=True)
        check(scan.returncode==1 and secret not in scan.stdout+scan.stderr, label+' 共用扫描器命中但不回显值')
        Path(str(out)+'.done').write_text('done')
        env['FAKE_NO_DONE']='1'
        p=subprocess.run(['sh','-c','. "$PI_SCRIPTS/completion-rules.sh"; completion_check "$FAKE_OUT" block:test'],env=env,capture_output=True,text=True)
        check(p.returncode==1 and not Path(str(out)+'.done').exists(), label+' 非空报告但产出泄漏仍拒绝收卷')
        calls=(state/'calls').read_text() if (state/'calls').exists() else ''
        check(secret not in p.stdout+p.stderr+calls, label+' 提示与通知不回显命中内容')
        artifact.unlink()
        Path(str(out)+'.done').write_text('done')
        p=subprocess.run(['sh','-c','. "$PI_SCRIPTS/completion-rules.sh"; completion_check "$FAKE_OUT" block:test'],env=env,capture_output=True,text=True)
        check(p.returncode==0, label+' 清除产出后可独立回读收卷')

    state,out,env=environment('scanner-negative')
    out.write_text('安全报告，无秘密')
    (out.parent/'fixtures.txt').write_text(
        'postgres://fixture:synthetic@localhost/test\npostgres://fixture:anything@host.invalid/db\n'
        'redis://fixture:synthetic@127.0.0.1/test\nmysql://fixture:synthetic@[::1]/test\n'
        'https://fixture:anything@host.invalid/test\nredis://localhost/test\n'
        'https://user@example.com/path\nnot-a-private-key\n'
        'redis://:synthetic@localhost/0\nredis://:anything@host.invalid/0\n'
        'redis://:@cache.example.com/0\n')
    for args, expected in [([str(out.parent)], 0), ([], 2), ([str(out.parent/'missing')], 2)]:
        scan=subprocess.run(['sh', str(scripts/'secret-scan.sh'), *args], capture_output=True, text=True)
        check(scan.returncode==expected, '共用扫描器干净/用法/缺文件退出码 '+str(expected))
    (out.parent/'external').symlink_to(out)
    Path(str(out)+'.done').write_text('done')
    env['FAKE_NO_DONE']='1'
    p=subprocess.run(['sh','-c','. "$PI_SCRIPTS/completion-rules.sh"; completion_check "$FAKE_OUT" block:test'],env=env,capture_output=True,text=True)
    check(p.returncode==1 and not Path(str(out)+'.done').exists(), '符号链接造成扫描不完整时不收卷')

    state,out,env=environment('shared-counter')
    for i in range(4):
        Path(str(out)+'.done').write_text('done')
        p=subprocess.run(['sh','-c','. "$PI_SCRIPTS/completion-rules.sh"; completion_check "$FAKE_OUT" block:test'],env=env,capture_output=True)
        check(p.returncode==(1 if i<3 else 2), '共享完成计数 '+str(i+1))
    check((state/'sends').read_text()=='3', '共享 helper 总共只发 3 次重写消息')
    out.write_text('非空报告'); Path(str(out)+'.done').write_text('done')
    p=subprocess.run(['sh','-c','. "$PI_SCRIPTS/completion-rules.sh"; completion_check "$FAKE_OUT" block:test'],env=env,capture_output=True)
    check(p.returncode==0, 'STUCK 后人工修复非空可完成')
    print(f'PASS: {passed} checks; no real Rex/Git push/production credentials used.', flush=True)
finally:
    # Only delete this suite's directory; no live watcher state or evidence is touched.
    shutil.rmtree(root)
PY
