#!/bin/sh
# usage: secret-scan.sh PATH... - 0 = clean, 1 = credential-shaped data found, 2 = input/scan error.
# Prints only path:line: kind, never the matched value. Scans nested and binary outputs too.
# Built-in patterns cover vendor tokens, private keys, JWTs and password URLs.
# Add custom formats with secret_pattern.<label> in dispatch.config.
[ $# -gt 0 ] || { echo "usage: secret-scan.sh PATH..." >&2; exit 2; }
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
exec python3 -I - "$here" "$@" <<'PY'
import os
import re
import sys

sys.path.insert(0, sys.argv.pop(1))
import dispatchconf

try:
    conf = dispatchconf.load(allow_missing=True)
    fixture_passwords = {pw.encode() for pw in dispatchconf.words(conf, 'secret_fixture_passwords')}
    extra = [(k.split('.', 1)[1], re.compile(v.encode())) for k, v in conf.items() if k.startswith('secret_pattern.')]
except (OSError, ValueError, re.error) as e:
    print(f'{dispatchconf.path()}:0: 配置无法读取（{type(e).__name__}）')
    sys.exit(2)

PATTERNS = [
    ('私钥', re.compile(rb'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY(?: BLOCK)?-----')),
    ('OpenAI API key', re.compile(rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,}')),
    ('Anthropic API key', re.compile(rb'\bsk-ant-(?:api\d+-)?[A-Za-z0-9_-]{32,}')),
    ('带密码的 URL', re.compile(
        rb'\b[a-z][a-z0-9+.-]*://(?P<userinfo>[^\s:/\'"]*:(?P<pw>[^\s/\'"]+))@'
        # Keep bracketed-host suffixes so [::1].evil.com is not exempt.
        # Recognize bare ::1 only at a host boundary; leave port templates opaque.
        rb'(?P<host>\[[^\]]+\][^\s:/?#@\'"]*|::1(?=[:/?#\s\'"]|$)|'
        rb'[^\s:/?#@\'"]+|[^\s/?#@\'"]+)', re.IGNORECASE)),
    ('JWT', re.compile(rb'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?![A-Za-z0-9_-])')),
    ('GitHub 令牌', re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})')),
] + extra

# Inspect the rest of the authority, not paths or later URLs on the same line.
# CI expressions may contain spaces and quotes; keep them as opaque port text.
# Reject ambiguous targets before applying any host exemption.
URL_SUFFIX = re.compile(rb'(?:\$\{\{[^\r\n]*?\}\}|[^\s/\?#\'\"])*')

CI_PORT = re.compile(rb':\$\{\{(?P<expression>(?:(?!\}\})[^\r\n])*)\}\}(?=[/?#]|$)')

# Start after the authority so spaces/quotes inside a CI port stay opaque.
# Stop at this URL's boundary; fragments cannot override libpq connection targets.
URL_TAIL = re.compile(rb'[^\s\'"#]*')
QUERY_TARGET = re.compile(rb'(?:^|[?&])host(?:addr)?=', re.IGNORECASE)

# Loopbacks are fixtures only with an allowlisted password or a CI template port.
def fixture(match):
    host = match.groupdict().get('host')
    if host is None:
        return False
    authority_end = URL_SUFFIX.match(match.string, match.end())
    suffix = authority_end.group()
    if b'@' in match.group('userinfo') or b'@' in suffix or b',' in suffix or b',' in host:
        return False
    host = host.lower()
    if host.endswith(b'.invalid'):
        return True
    if host not in (b'localhost', b'127.0.0.1', b'::1', b'[::1]'):
        return False
    query = URL_TAIL.match(match.string, authority_end.end()).group().partition(b'?')[2]
    if QUERY_TARGET.search(query):
        return False
    port = CI_PORT.match(suffix)
    return match.group('pw') in fixture_passwords or bool(port and port.group('expression').strip())

def scan_error(path):
    global errors
    print(f'{path}:0: 无法完成安全扫描')
    errors += 1

def files(paths):
    for path in paths:
        if os.path.islink(path):
            scan_error(path)
        elif os.path.isdir(path):
            for root, dirs, names in os.walk(path, onerror=lambda _: scan_error(path)):
                for name in list(dirs):
                    nested = os.path.join(root, name)
                    if os.path.islink(nested):
                        scan_error(nested)
                        dirs.remove(name)
                for name in sorted(names):
                    yield os.path.join(root, name)
        elif os.path.isfile(path):
            yield path
        else:
            scan_error(path)

hits = 0
errors = 0
for path in files(sys.argv[1:]):
    try:
        if os.path.islink(path) or not os.path.isfile(path):
            raise OSError('not a regular file')
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        scan_error(path)
        continue
    for n, line in enumerate(data.splitlines(), 1):
        for kind, pattern in PATTERNS:
            if any(not fixture(m) for m in pattern.finditer(line)):
                print(f'{path}:{n}: {kind}')
                hits += 1
sys.exit(2 if errors else 1 if hits else 0)
PY
