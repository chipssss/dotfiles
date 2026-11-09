#!/bin/sh
# 0 = safe, 1 = needs human, 2 = incomplete dialog. Never echo command text.
safe_ask() {
  # shellcheck disable=SC2034 # Fixed reason consumed by the supervisor, never command text.
  if APPROVAL_REASON=$(PI_APPROVAL_TEXT="$1" python3 -B - <<'PY'
import fnmatch
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

sys.path.insert(0, os.environ['PI_SCRIPTS'])
import dispatchconf

text = os.environ.pop('PI_APPROVAL_TEXT')
header = 'Confirm external or irreversible action'
if header not in text:
    print('等待完整确认对话')
    sys.exit(2)
text = text.rsplit(header, 1)[1]
menu = re.search(r'(?m)^[ \t│┃]*↑↓[ \t]+navigate\b[^\n]*$', text)
if not menu:
    print('等待完整确认对话')
    sys.exit(2)


def deny(reason):
    print(reason)
    sys.exit(1)


try:
    conf = dispatchconf.load()
    dispatchconf.approval_policy(conf)
except (OSError, ValueError):
    deny('dispatch 配置缺失或策略不完整，需要人工确认')
PROTECTED = ['main', 'master', *dispatchconf.words(conf, 'protected_branches')]
TEMP_CONTAINERS = tuple(dispatchconf.words(conf, 'temp_containers'))
DB_WRAPPER = conf.get('db_wrapper', '')
match = re.search(r'Allow ([^?]+)\?', text)
if not match:
    deny('无法识别确认类型')
kind = match[1]
command = text[match.end():menu.start()].strip()
# A capture is not a shell AST. Do not guess at soft wrapping, nested shells,
# expansions, redirects or compound commands. Each needs human authorization.
if re.search(r'\b(?:ps|pgrep)\b', command):
    deny('进程命令行查询需要人工确认')
if re.search(r'(?<![\w-])psql(?:\s|$)', command):
    deny(f'请改用 {DB_WRAPPER}' if DB_WRAPPER else '数据库命令需要人工确认')
if any(c in command for c in '\n\r;&|<>$`()\\'):
    deny('复合命令、展开或重定向需要人工确认')
try:
    words = shlex.split(command, comments=False)
except ValueError:
    deny('命令不完整或引号无法解析')
if not words:
    deny('没有命令')
# Only known executable spellings, not arbitrary same-basename programs.
exe = words[0]
if exe in ('/bin/rm', '/usr/bin/rm'):
    exe = 'rm'
if exe in ('/usr/bin/git', '/bin/git'):
    exe = 'git'
args = words[1:]
cwd = os.environ.get('PI_APPROVE_CWD')


def protected(ref):
    ref = ref.removeprefix('refs/heads/')
    return any(fnmatch.fnmatchcase(ref, pattern) for pattern in PROTECTED)


def branches_safe(upstream_matters=True):
    if not cwd or not os.path.isabs(cwd):
        deny('裸 git push 缺少可验证的工作目录')
    try:
        def git(*args):
            return subprocess.check_output(['git', '-C', cwd, *args], stderr=subprocess.DEVNULL,
                                           text=True, timeout=3).strip()
        head = git('rev-parse', '--abbrev-ref', 'HEAD')
        if head == 'HEAD' or protected(head):
            deny('当前分支是共享分支')
        if upstream_matters:
            upstream = git('rev-parse', '--abbrev-ref', '@{u}')
            remote = git('config', '--get', f'branch.{head}.remote')
            upstream = upstream.removeprefix(remote + '/') if remote != '.' else upstream
            if protected(upstream):
                deny('上游是共享分支')
    except (subprocess.SubprocessError, OSError):
        deny('无法读取当前分支或上游')


if kind == 'git push' and exe == 'git' and args[:1] == ['push']:
    args = args[1:]
    if any(a.startswith(('--force', '+', ':')) or
           (a.startswith('-') and a not in ('-u', '--set-upstream')) for a in args):
        deny('git push 包含强推、删除或不支持的选项')
    args = [a for a in args if a not in ('-u', '--set-upstream')]
    if args and not re.fullmatch(r'[A-Za-z0-9_.-]+', args[0]):
        deny('remote 无法验证')
    if len(args) < 2:
        branches_safe()
    else:
        for ref in args[1:]:
            if ref.count(':') > 1:
                deny('refspec 无法验证')
            dest = ref.split(':', 1)[-1]
            if not re.fullmatch(r'(?:refs/heads/)?[A-Za-z0-9_./-]+', dest) or protected(dest):
                deny('目标是共享分支或无法验证')
            if ref == 'HEAD':
                branches_safe(False)
            elif dest == 'HEAD':
                branches_safe()
    print('功能分支 push')
    sys.exit(0)


def inside(path, root):
    return path != root and root in path.parents


def temporary(target):
    if any(c in target for c in '~*?[]{}'):
        return False
    raw = Path(target)
    if not raw.is_absolute():
        if not cwd or not os.path.isabs(cwd):
            return False
        raw = Path(cwd) / raw
    # Reject traversal even if the final resolution returns to a temporary root.
    if '..' in raw.parts:
        return False
    roots = []
    for root in dispatchconf.words(conf, 'temp_dirs', '/tmp/ /private/tmp/ .tmp/'):
        p = Path(root)
        if not p.is_absolute():
            if not cwd or root != '.tmp/':
                continue
            p = Path(cwd).resolve() / '.tmp'
            if p.is_symlink():
                continue
        resolved_root = p.resolve()
        system_tmp = Path('/tmp').resolve()
        if root != '.tmp/' and resolved_root != system_tmp and not inside(resolved_root, system_tmp):
            continue
        roots.append(resolved_root)
    try:
        canonical = raw.resolve()
        if not any(inside(canonical, root) for root in roots):
            return False
        # realpath alone misses an escape followed by a return into tmp.
        current = Path(raw.anchor)
        for component in raw.parts[1:]:
            current /= component
            if current.is_symlink():
                if not current.exists():
                    return False
                resolved = current.resolve(strict=True)
                if not any(resolved == root or inside(resolved, root) for root in roots):
                    return False
        return True
    except (OSError, RuntimeError):
        return False


if kind == 'recursive deletion':
    if exe == 'rm':
        targets = []
        options = True
        for arg in args:
            if options and arg == '--':
                options = False
            elif options and arg.startswith('-'):
                if not re.fullmatch(r'-[rfRv]+|--recursive|--force', arg):
                    deny('不支持的 rm 选项')
            else:
                targets.append(arg)
        if targets and all(temporary(t) for t in targets):
            print('允许根内的临时目录删除')
            sys.exit(0)
    elif exe == 'docker' and args[:1] == ['rm']:
        targets = [a for a in args[1:] if not a.startswith('-')]
        flags = [a for a in args[1:] if a.startswith('-')]
        if targets and TEMP_CONTAINERS and all(re.fullmatch(r'-[fv]+', f) for f in flags) and all(
                re.fullmatch(r'[A-Za-z0-9_.-]+', t) and t.startswith(TEMP_CONTAINERS) for t in targets):
            print('临时容器删除')
            sys.exit(0)
# PR bodies may contain shell metacharacters, so those requests conservatively wait too.
if kind == 'GitHub pull-request mutation' and exe == 'gh' and args[:2] in (['pr', 'create'], ['pr', 'edit']):
    if '--delete-branch' not in args and '--admin' not in args:
        print('PR 创建或编辑')
        sys.exit(0)
if DB_WRAPPER and words[0] == DB_WRAPPER:
    print('配置的数据库包装脚本')
    sys.exit(0)
deny('此操作不在简单命令自动审批范围内')
PY
  ); then
    return 0
  else
    return $?
  fi
}

approval_key() {
  printf '%s' "$1" | awk '
    /Confirm external or irreversible action/ { buf=""; collecting=1 }
    collecting { if (/↑↓[[:space:]]+navigate/) collecting=0; else buf=buf $0 "\n" }
    END { printf "%s", buf }' | cksum
}
