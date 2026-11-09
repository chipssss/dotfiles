#!/usr/bin/env bash
# Exercise the scanner CLI with synthetic URLs, never real credentials.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
exec python3 -B - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

scanner = Path(os.environ['ROOT']) / 'home/dispatch/secret-scan.sh'
with tempfile.TemporaryDirectory(prefix='dispatch-secret-scan-') as tmp:
    root = Path(tmp)
    config = root / 'config'
    config.write_text('')
    env = dict(os.environ, DISPATCH_CONFIG=str(config))
    artifact = root / 'artifact'
    # Exact reported CI line with the password redacted, including the port expression.
    artifact.write_text("DAILY_TEST_DATABASE_URL: postgresql://postgres:<pw>@127.0.0.1:${{ job.services.postgres.ports['5432'] }}/daily_tests_admin\n")
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 0 and not scan.stdout and not scan.stderr, 'CI loopback URL must not be reported as a credential'
    print('PASS: redacted CI loopback URL is clean', flush=True)

    passed = 1
    def check_url(host, port, expected, user='postgres', scheme='postgresql'):
        global passed
        url = f'{scheme}://{user}:<pw>@{host}{port}/daily_tests_admin'
        artifact.write_text('DAILY_TEST_DATABASE_URL: ' + url + '\n')
        scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
        assert scan.returncode == expected, f'{host}, {port!r}: expected {expected}, got {scan.returncode}'
        assert not scan.stderr and url not in scan.stdout and '<pw>' not in scan.stdout, 'scanner must not echo credentials'
        if expected == 0:
            assert not scan.stdout, 'loopback URL must produce no findings'
        else:
            assert scan.stdout == f'{artifact}:1: 带密码的 URL\n', 'non-loopback URL must produce a password-URL finding'
        passed += 1

    # Match only the complete host, independently of user, password or port syntax.
    ports = ['', ':5432', ":${{ job.services.postgres.ports['5432'] }}"]
    for host in ['127.0.0.1', '::1', '[::1]', 'localhost', 'LOCALHOST']:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 0, user=user)

    # A loopback-looking prefix or substring is never a loopback host exemption.
    for host in ['127.0.0.1.evil.com', 'localhost.example', '[::1].evil.com',
                 '::1.evil.com', '::1evil', '[::1]evil', 'evil-localhost',
                 '127.0.0.10', '127.1.0.1', '0.0.0.0', '::2', '[::2]',
                 '[2001:db8::1]', 'db.example.com']:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 1, user=user)

    # Loopback exemptions apply only to password URLs, not custom secret formats.
    config.write_text('secret_pattern.redacted-test = <pw>\n')
    artifact.write_text('redis://' + ':<pw>@localhost:6379/0\n')
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 1 and scan.stdout == f'{artifact}:1: redacted-test\n' and not scan.stderr
    passed += 1
    print(f'PASS: {passed} scanner CLI checks (CI regression, exact loopbacks, remote/spoofed hosts, redaction, custom rules)')
PY
