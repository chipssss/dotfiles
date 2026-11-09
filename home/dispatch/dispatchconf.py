"""Machine-wide safety settings shared by the launcher, supervisor and scanner.

Read key = value lines from DISPATCH_CONFIG, else ~/.config/dispatch/config.
Repository selection and runtime directories are CLI/environment inputs, not policy.
"""
import os
import re
from pathlib import Path

# The single source for omitted settings, shared by every policy consumer.
DEFAULTS = dict(ports='3110-3999', approval_mode='strict', protected_branches='',
                temp_dirs='/tmp/ /private/tmp/ .tmp/', secret_fixture_passwords='postgres synthetic')
KEYS = set(DEFAULTS)
DEFAULT = Path.home() / '.config/dispatch/config'


def path():
    return Path(os.environ['DISPATCH_CONFIG']).expanduser() if os.environ.get('DISPATCH_CONFIG') else DEFAULT


def load(p=None, allow_missing=False):
    p = Path(p) if p else path()
    if not p.exists():
        if allow_missing and not p.is_symlink() and not os.environ.get('DISPATCH_CONFIG'):
            return effective({})
        raise ValueError(f'配置 {p} 不存在或链接失效')
    conf = {}
    for n, line in enumerate(p.read_text().splitlines(), 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        key, sep, value = s.partition('=')
        key, value = key.strip(), value.strip()
        if not sep or key in conf or (key not in KEYS and not key.startswith('secret_pattern.')):
            raise ValueError(f'{p}:{n}: 重复、未知配置项或缺少等号')
        conf[key] = value
    conf = effective(conf)
    validate(conf)
    return conf


def effective(conf):
    """Fill omitted settings without replacing explicit empty values."""
    return {**DEFAULTS, **conf}


def validate(conf):
    conf = effective(conf)
    if conf['approval_mode'] not in ('strict', 'generic'):
        raise ValueError('approval_mode 必须是 strict 或 generic')
    for pattern in words(conf, 'protected_branches'):
        if not re.fullmatch(r'[A-Za-z0-9_./*?-]+', pattern):
            raise ValueError('protected_branches 格式不合法')
    for root in words(conf, 'temp_dirs'):
        if root != '.tmp/' and (not root.startswith(('/tmp/', '/private/tmp/')) or '..' in Path(root).parts):
            raise ValueError('temp_dirs 仅支持临时根的子目录或 .tmp/')
    ports = conf['ports']
    if not re.fullmatch(r'[0-9]+-[0-9]+', ports):
        raise ValueError('ports 应写成 起-止')
    first, last = map(int, ports.split('-'))
    if not 1024 <= first <= last - 9 <= 65526:
        raise ValueError('ports 必须在 1024-65535 内且至少含十个端口')
    for key, pattern in conf.items():
        if key.startswith('secret_pattern.'):
            re.compile(pattern)


def approval_policy(conf):
    conf = effective(conf)
    validate(conf)
    if conf['approval_mode'] != 'generic' and not words(conf, 'protected_branches'):
        raise ValueError('严格模式必须明确声明非空 protected_branches')


def protected_branches(conf):
    """Built-in protected branches cannot be removed by machine policy."""
    return ['main', 'master', *words(conf, 'protected_branches')]


def words(conf, key):
    return conf.get(key, DEFAULTS.get(key, '')).split()
