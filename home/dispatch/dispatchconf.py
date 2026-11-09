"""Project config shared by dispatch, the approval rules and the secret scanner.

The file is `key = value` lines; `#` starts a comment line. Lookup order:
$DISPATCH_CONFIG, then ~/.config/dispatch/config. See dispatch.config.example.
"""
import os
import re
from pathlib import Path

KEYS = {'repo', 'state_dir', 'evidence_dir', 'worktree_root', 'ports', 'worker_model',
        'worker_thinking', 'role_brief', 'review_checklist', 'merge_script', 'merge_commit_bases',
        'card_command', 'card_env', 'card_log', 'protected_branches', 'temp_dirs',
        'temp_containers', 'db_wrapper', 'secret_fixture_passwords', 'approval_mode'}

DEFAULT = Path.home() / '.config/dispatch/config'


def path():
    return Path(os.environ['DISPATCH_CONFIG']) if os.environ.get('DISPATCH_CONFIG') else DEFAULT


def load(p=None, allow_missing=False):
    """Fail closed. Only credential scanning may explicitly use built-in-only rules."""
    p = Path(p) if p else path()
    if not p.exists():
        if allow_missing and not p.is_symlink() and not os.environ.get('DISPATCH_CONFIG'):
            return {}
        raise ValueError(f'配置 {p} 不存在或链接失效')
    conf = {}
    for n, line in enumerate(p.read_text().splitlines(), 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        key, sep, value = s.partition('=')
        if not sep or not key.strip():
            raise ValueError(f'{p}:{n}: 需要 key = value')
        key, value = key.strip(), value.strip()
        if key in conf or (key not in KEYS and not key.startswith('secret_pattern.')):
            raise ValueError(f'{p}:{n}: 重复或未知配置项')
        conf[key] = value
    validate(conf)
    return conf


def validate(conf):
    mode = conf.get('approval_mode', 'project')
    if mode not in ('project', 'generic'):
        raise ValueError('approval_mode 必须是 project 或 generic')
    for pattern in words(conf, 'protected_branches'):
        if not re.fullmatch(r'[A-Za-z0-9_./*?-]+', pattern):
            raise ValueError('protected_branches 格式不合法')
    for root in words(conf, 'temp_dirs'):
        if root != '.tmp/' and (not root.startswith(('/tmp/', '/private/tmp/')) or '..' in Path(root).parts):
            raise ValueError('temp_dirs 仅支持临时根的子目录或 .tmp/')
    for prefix in words(conf, 'temp_containers'):
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', prefix):
            raise ValueError('temp_containers 格式不合法')
    wrapper = conf.get('db_wrapper', '')
    if wrapper and (any(c in wrapper for c in ' \t\n$`;&|') or '..' in Path(wrapper).parts):
        raise ValueError('db_wrapper 格式不合法')


def approval_policy(conf):
    validate(conf)
    if conf.get('approval_mode') != 'generic' and not words(conf, 'protected_branches'):
        raise ValueError('project 模式必须明确声明非空 protected_branches')


def words(conf, key, default=''):
    return conf.get(key, default).split()


def file(conf, key):
    value = conf.get(key)
    return Path(os.path.expanduser(value)) if value else None
