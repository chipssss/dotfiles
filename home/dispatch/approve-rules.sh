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
    deny('数据库命令需要人工确认')
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


def git(*args, optional=False):
    p = subprocess.run(['git', '-C', cwd, *args], capture_output=True, text=True, timeout=3)
    if p.returncode and not (optional and p.returncode == 1):
        deny('无法解析仓库的实际 push 配置')
    return p.stdout.strip()


def config(key):
    return git('config', '--get-all', key, optional=True).splitlines()


def one(key, default=''):
    values = config(key)
    if len(values) > 1:
        deny('配置有多个值，无法确认推送目标')
    return values[0] if values else default


def branch_ref(ref, source=False):
    # A short destination can resolve to a remote-only tag or symbolic HEAD.
    # Without contacting the remote, only a fully qualified branch is provable.
    if not source and not ref.startswith('refs/heads/'):
        deny('目标必须是明确的 refs/heads/ 分支，短名称可能是远端标签')
    if ref == 'HEAD' and source:
        ref = head
    name = ref.removeprefix('refs/heads/')
    if (ref.startswith('refs/') and not ref.startswith('refs/heads/')) or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_./-]*', name):
        deny('只自动批准明确的分支引用，不批准标签')
    if subprocess.run(['git', 'check-ref-format', 'refs/heads/' + name], capture_output=True).returncode:
        deny('分支引用无法验证')
    # A bare destination may resolve to an existing tag instead of a branch.
    if not ref.startswith('refs/heads/'):
        p = subprocess.run(['git', '-C', cwd, 'show-ref', '--verify', '--quiet', 'refs/tags/' + name], capture_output=True)
        if p.returncode != 1:
            deny('标签或同名歧义引用需要人工确认')
    if source:
        git('show-ref', '--verify', 'refs/heads/' + name)
    if protected(name):
        deny('推送涉及受保护分支')
    return 'refs/heads/' + name


def authorize_push(push_args):
    global head
    if not cwd or not os.path.isabs(cwd):
        deny('git push 缺少可验证的工作目录')
    if any(a.startswith(('--force', '+', ':')) or
           (a.startswith('-') and a not in ('-u', '--set-upstream')) for a in push_args):
        deny('git push 包含标签、强推、删除或不支持的选项')
    push_args = [a for a in push_args if a not in ('-u', '--set-upstream')]
    head = git('symbolic-ref', '--quiet', '--short', 'HEAD')
    branch_ref(head, source=True)
    remote = push_args[0] if push_args else (one(f'branch.{head}.pushRemote') or one('remote.pushDefault') or
                                            one(f'branch.{head}.remote') or 'origin')
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*', remote) or remote not in git('remote').splitlines():
        deny('remote 无法验证')
    if one('push.followTags', 'false').lower() not in ('false', 'no', 'off', '0') or one(f'remote.{remote}.mirror', 'false').lower() not in ('false', 'no', 'off', '0'):
        deny('隐式标签或镜像推送需要人工确认')
    mappings = config(f'remote.{remote}.push')
    refs = push_args[1:]
    if not refs:
        if mappings:
            refs = mappings
        else:
            mode = one('push.default', 'simple')
            if mode == 'current':
                refs = [head + ':refs/heads/' + head]
            elif mode in ('simple', 'upstream'):
                upstream = config(f'branch.{head}.merge')
                if len(upstream) != 1 or one(f'branch.{head}.remote') != remote:
                    deny('无法确定 push 的上游目标')
                if mode == 'simple' and upstream[0] != 'refs/heads/' + head:
                    deny('simple 模式的上游分支名不一致')
                refs = [head + ':' + upstream[0]]
            else:
                deny('push.default 无法安全解析')
    for ref in refs:
        if ref.count(':') > 1 or ref.startswith(('+', ':')) or '*' in ref:
            deny('通配、删除或多义 refspec 需要人工确认')
        if ':' in ref:
            src, dest = ref.split(':')
            branch_ref(src, source=True)
            branch_ref(dest)
        else:
            src = branch_ref(ref, source=True)
            # Git applies remote.<name>.push destination mappings even to an explicit bare source.
            destinations = []
            for mapping in mappings:
                if mapping.count(':') != 1 or '*' in mapping or mapping.startswith(('+', ':')):
                    deny('remote push 映射无法安全解析')
                configured_src, dest = mapping.split(':')
                if branch_ref(configured_src, source=True) == src:
                    destinations.append(dest)
            if len(destinations) > 1:
                deny('push 源分支对应多个目标')
            branch_ref(destinations[0] if destinations else src)


if kind == 'git push' and exe == 'git' and args[:1] == ['push']:
    try:
        authorize_push(args[1:])
    except (subprocess.SubprocessError, OSError, ValueError):
        deny('无法解析实际推送目标，需要人工确认')
    print('已解析目标的功能分支 push')
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
