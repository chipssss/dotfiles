#!/bin/sh
# Shared by pi-worker (also via dispatch). 0 = safe, 1 = needs human, 2 = incomplete dialog.
# Never print the command: confirmation text can contain credentials.
# Needs $PI_SCRIPTS (for dispatchconf.py). Project values come from dispatch.config:
# protected_branches, temp_dirs, temp_containers, db_wrapper (see dispatch.config.example).
safe_ask() {
  # shellcheck disable=SC2034 # Read by the callers, never includes command text.
  if APPROVAL_REASON=$(PI_APPROVAL_TEXT="$1" python3 - <<'PY'
import fnmatch
import os
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
except (OSError, ValueError):
    deny('dispatch 配置无法读取')
PROTECTED = dispatchconf.words(conf, 'protected_branches', 'main master')
TEMP_DIRS = tuple(dispatchconf.words(conf, 'temp_dirs', '/tmp/ /private/tmp/ .tmp/'))
TEMP_CONTAINERS = tuple(dispatchconf.words(conf, 'temp_containers'))
DB_WRAPPER = conf.get('db_wrapper', '')

match = re.search(r'Allow ([^?]+)\?', text)
if not match:
    deny('无法识别确认类型')
kind = match[1]
# Pi's ExtensionSelector renders a distinct ↑↓ navigate footer.
command = text[match.end():menu.start()]
# The pane soft-wraps long commands; a wrap between `git` and `push` is not a command boundary.
command = re.sub(r'\bgit[ \t]*\n[ \t]*push\b', 'git push', command)
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=';&|<>\n')
    lexer.whitespace = ' \t\r'  # Preserve newlines as shell command boundaries.
    lexer.whitespace_split = True
    lexer.commenters = '#'
    tokens = list(lexer)
except ValueError:
    deny('命令不完整或引号无法解析')
segments, part = [], []
for token in tokens + [';']:
    if re.fullmatch(r'[;&|<>\n]+', token):
        if part:
            segments.append(part)
            part = []
    else:
        part.append(token)

# Include quoted shell payloads and terminal soft wraps, not just top-level commands.
def check_process_queries(words):
    for i, word in enumerate(words):
        executable = word.rsplit('/', 1)[-1]
        if executable == 'ps':
            deny('进程命令行查询被拒绝；请用 lsof -t 或 pgrep -x 查询 PID')
        if executable == 'pgrep' and any(
            arg in ('--full', '--list-full') or arg.startswith('--full=')
            or (arg.startswith('-') and not arg.startswith('--') and any(flag in arg for flag in 'fa'))
            for arg in words[i+1:]
        ):
            deny('进程命令行匹配被拒绝；请用 pgrep -x 查询 PID')
        if any(c.isspace() for c in word):
            try:
                nested = shlex.split(word)
            except ValueError:
                continue
            if len(nested) > 1:
                check_process_queries(nested)

for part in segments:
    check_process_queries(part)
try:
    check_process_queries(shlex.split(command.replace('\n', ' '), comments=True))
except ValueError:
    deny('命令不完整或引号无法解析')

# db_wrapper names the one script allowed to reach a database with credentials.
wrapper_re = r'(?:.*/)?' + re.escape(DB_WRAPPER) if DB_WRAPPER else None
wrapper = wrapper_re and any(
    re.fullmatch(wrapper_re, p[0])
    or (p[0] in ('sh', 'bash') and len(p) > 1 and re.fullmatch(wrapper_re, p[1]))
    for p in segments
)
risky_psql = re.search(r'\bpsql\b', command) and re.search(
    r'\bop\s+read\b|DATABASE_URL|postgres(?:ql)?://', command)
# Merely mentioning the wrapper (or invoking it alongside raw psql) is not a bypass.
raw_psql = re.search(r'\bpsql\b', re.sub(r'(?:[^\s;|&]*/)?' + re.escape(DB_WRAPPER), '', command)
                     if DB_WRAPPER else command)
if risky_psql and (not wrapper or raw_psql):
    deny(f'请改用 {DB_WRAPPER}' if DB_WRAPPER else '带凭据的数据库命令需要人工确认')


def protected(ref):
    ref = ref.removeprefix('refs/heads/')
    return any(fnmatch.fnmatchcase(ref, pattern) for pattern in PROTECTED)


def branches_safe(cwd, upstream_matters=True):
    if not cwd or not os.path.isabs(cwd) or any(c in cwd for c in '$`\n'):
        deny('裸 git push 缺少可验证的 cd <dir>')
    try:
        def git(*args):
            return subprocess.check_output(
                ['git', '-C', cwd, 'rev-parse', '--abbrev-ref', *args],
                stderr=subprocess.DEVNULL, text=True, timeout=3).strip()
        head = git('HEAD')
        if not upstream_matters:
            # `git push <remote> HEAD` writes the same-named branch whatever the upstream is.
            if head == 'HEAD' or protected(head):
                deny('git push HEAD 的当前分支是共享分支')
            return
        upstream = git('@{u}')
        remote = subprocess.check_output(
            ['git', '-C', cwd, 'config', '--get', f'branch.{head}.remote'],
            stderr=subprocess.DEVNULL, text=True, timeout=3).strip()
    except (subprocess.SubprocessError, OSError):
        deny('裸 git push 无法读取当前分支或上游')
    upstream = upstream.removeprefix(remote + '/') if remote != '.' else upstream
    if head == 'HEAD' or protected(head) or protected(upstream):
        deny('裸 git push 的当前分支或上游是共享分支')


# A terminal soft wrap is indistinguishable from a shell newline in a capture.
# Check shared targets/force flags with newlines folded too, before the bare-push check.
for continuation in re.findall(r'\bgit\s+push\b([^;&|<>]*)', command):
    try:
        folded_args = shlex.split(continuation)
    except ValueError:
        deny('换行 push 命令无法解析')
    if any(a.startswith(('--force', '+', ':')) or a in ('-f', '--delete', '-d')
           or protected(a.rsplit(':', 1)[-1]) for a in folded_args):
        deny('git push 包含共享目标、强推或删除')

pushes = []
# pi-worker exports the pane's working directory; pi starts every command there.
cwd = os.environ.get('PI_APPROVE_CWD') or None
for p in segments:
    if p[0] == 'cd':
        cwd = p[1] if len(p) == 2 else None
    for i in range(len(p) - 1):
        if p[i:i+2] != ['git', 'push']:
            continue
        args = p[i+2:]
        if any(a.startswith('--force') or a in ('-f', '--delete', '-d')
               or a.startswith('+') or (a.startswith('-') and a not in ('-u', '--set-upstream'))
               for a in args):
            deny('git push 包含强推、删除或不支持的选项')
        args = [a for a in args if a not in ('-u', '--set-upstream')]
        if not args or len(args) == 1:
            branches_safe(cwd)
        else:
            # A URL can hide credentials and push configuration; only named remotes.
            if not re.fullmatch(r'[A-Za-z0-9_.-]+', args[0]):
                deny('git push 的 remote 无法验证')
            for ref in args[1:]:
                dest = ref.split(':', 1)[-1]
                if not dest or ref.startswith(':') or protected(dest):
                    deny('git push 的目标是共享分支或删除 refspec')
                if ref == 'HEAD':
                    branches_safe(cwd, upstream_matters=False)
                elif dest == 'HEAD':
                    branches_safe(cwd)
                elif not re.fullmatch(r'(?:refs/heads/)?[A-Za-z0-9_./-]+', dest):
                    deny('git push 的 refspec 无法验证')
        pushes.append(p)

if kind == 'git push' and pushes:
    print('功能分支 push')
    sys.exit(0)
if kind == 'GitHub pull-request mutation':
    if re.search(r'pr\s+(?:merge|close)|--admin|merge-when-green|pulls/[0-9]+/merge|--delete-branch', command):
        deny('PR 合并或关闭需要人工确认')
    print('PR 创建或编辑')
    sys.exit(0)
if kind == 'recursive deletion':
    found = False
    for p in segments:
        for i, word in enumerate(p):
            if word != 'rm':
                continue
            args = p[i+1:]
            targets = [a for a in args if not a.startswith('-')]
            if not targets:
                deny('无法解析删除目标')
            if i > 0 and p[i-1] == 'docker':
                if not TEMP_CONTAINERS or not all(
                        re.fullmatch(r'[A-Za-z0-9_.-]+', t) and t.startswith(TEMP_CONTAINERS) for t in targets):
                    deny('只自动允许配置的临时容器')
            else:
                for target in targets:
                    normalized = os.path.normpath(target)
                    if any(c in target for c in '$`*?[]{}') or not (
                        normalized.startswith(TEMP_DIRS)
                    ):
                        deny('删除目标不是允许的临时目录')
            found = True
    if found:
        print('临时目录或临时容器删除')
        sys.exit(0)
if risky_psql and wrapper and not raw_psql:
    print('数据库包装脚本')
    sys.exit(0)
deny('此操作不在自动审批范围内')
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
