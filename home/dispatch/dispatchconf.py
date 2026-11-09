"""Project config shared by dispatch, the approval rules and the secret scanner.

The file is `key = value` lines; `#` starts a comment line. Lookup order:
$DISPATCH_CONFIG, then ~/.config/dispatch/config. See dispatch.config.example.
"""
import os
from pathlib import Path

DEFAULT = Path.home() / '.config/dispatch/config'


def path():
    return Path(os.environ['DISPATCH_CONFIG']) if os.environ.get('DISPATCH_CONFIG') else DEFAULT


def load(p=None):
    """{} when no config exists; raises ValueError for an explicit missing or malformed file."""
    p = Path(p) if p else path()
    if not p.exists():
        if os.environ.get('DISPATCH_CONFIG'):
            raise ValueError(f'DISPATCH_CONFIG 指向的 {p} 不存在')
        return {}
    conf = {}
    for n, line in enumerate(p.read_text().splitlines(), 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        key, sep, value = s.partition('=')
        if not sep or not key.strip():
            raise ValueError(f'{p}:{n}: 需要 key = value')
        conf[key.strip()] = value.strip()
    return conf


def words(conf, key, default=''):
    return conf.get(key, default).split()


def file(conf, key):
    value = conf.get(key)
    return Path(os.path.expanduser(value)) if value else None
