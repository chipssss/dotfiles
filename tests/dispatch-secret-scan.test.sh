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
    # Synthetic service-container URL with a redacted password and CI port expression.
    artifact.write_text("TEST_DATABASE_URL: postgresql://postgres:<pw>@127.0.0.1:${{ job.services.postgres.ports['5432'] }}/app_test\n")
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 0 and not scan.stdout and not scan.stderr, 'CI loopback URL must not be reported as a credential'
    print('PASS: redacted CI loopback URL is clean', flush=True)

    passed = 1
    def check_url(host, port, expected, user='postgres', scheme='postgresql', password='<pw>', query=''):
        global passed
        url = f'{scheme}://{user}:{password}@{host}{port}/app_test{query}'
        artifact.write_text('TEST_DATABASE_URL: ' + url + '\n')
        scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
        assert scan.returncode == expected, f'{host}, {port!r}, {query!r}: expected {expected}, got {scan.returncode}'
        assert not scan.stderr and url not in scan.stdout and '<pw>' not in scan.stdout, 'scanner must not echo credentials'
        if expected == 0:
            assert not scan.stdout, 'loopback URL must produce no findings'
        else:
            assert scan.stdout == f'{artifact}:1: 带密码的 URL\n', 'non-loopback URL must produce a password-URL finding'
        passed += 1

    # libpq query parameters can override an otherwise loopback CI target.
    check_url('localhost', ':${{ job.services.postgres.ports[5432] }}', 1,
              user='app_test', query='?host=db.prod.example.com')

    # A later @ or libpq host separator must never inherit a loopback exemption.
    for host, port in [
        ('localhost', '@db.prod.example.com:5432'),
        ('[::1]', ':x@db.prod.example.com'),
        ('127.0.0.1', '@cache.prod.example.com'),
        ('localhost', ':5432,db.prod.example.com:5432'),
        ('[::1]', ':5432,db.prod.example.com'),
        ('::1', ':5432,db.prod.example.com'),
        ('localhost,db.example.invalid', ''),
        ('db.example.invalid', '@localhost:5432'),
        ('@localhost', ':5432'),
        ('localhost', ":${{ job.services.db.ports['5432'] }}@db.example.com"),
        ('127.0.0.1', ":${{ job.services.db.ports['5432'] }},db.example.com"),
    ]:
        check_url(host, port, 1)
        check_url(host, port, 1, user='', scheme='redis')
        check_url(host, port, 1, password='synthetic')

    # Multiple @ in userinfo are findings even if the final host is loopback.
    check_url('localhost', ':5432', 1, user='user@name', password='synthetic')
    ci_port = ":${{ job.services.db.ports['5432'] }}"
    check_url('localhost', ci_port, 1, user='user@name')
    check_url('localhost', ci_port, 1, password='synthetic@part')

    # Exact loopbacks need a fixture password OR a complete CI port expression.
    ports = ['', ':5432', ":${{ job.services.postgres.ports['5432'] }}"]
    loopbacks = ['127.0.0.1', '::1', '[::1]', 'localhost', 'LOCALHOST']
    for host in loopbacks:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 0 if port == ports[2] else 1, user=user)
                check_url(host, port, 0, user=user, password='synthetic')

    # Both loopback exemptions reject target overrides, even empty/local values.
    # Names are case-insensitive and can follow either ? or & in the query.
    target_queries = [
        '?host=db.prod.example.com',
        '?hostaddr=203.0.113.7',
        '?sslmode=disable&host=db.prod.example.com',
        '?sslmode=disable&hostaddr=203.0.113.7',
        '?HOST=db.prod.example.com',
        '?application_name=probe&HoStAdDr=203.0.113.7',
        '?host=', '?hostaddr=', '?host=localhost',
    ]
    harmless_queries = [
        '?sslmode=disable', '?application_name=hostx',
        '?application_name=host=db.prod.example.com',
        '?myhost=db.prod.example.com', '?hostaddress=203.0.113.7',
        '/host=db.prod.example.com', '/&host=db.prod.example.com',
        '#?host=db.prod.example.com', '?sslmode=disable#&host=db.prod.example.com',
    ]
    for host in loopbacks:
        for port, password in [('', 'synthetic'), (':5432', 'postgres'),
                               (ports[2], '<pw>'), (ports[2], 'synthetic')]:
            for query in target_queries:
                check_url(host, port, 1, password=password, query=query)
            for query in harmless_queries:
                check_url(host, port, 0, password=password, query=query)

    # A following URL's query cannot revoke the first URL's exemption.
    later_target = 'postgresql://' + 'db.example.com/app_test?host=db.prod.example.com'
    for port, password in [(':5432', 'synthetic'), (ports[2], '<pw>')]:
        first_url = 'postgresql://' + f'app_test:{password}@localhost{port}/app_test?sslmode=disable'
        for separator in [' ', '\t', '"', "'"]:
            artifact.write_text(first_url + separator + later_target + '\n')
            scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
            assert scan.returncode == 0 and not scan.stdout and not scan.stderr, 'queries belong only to their own URL'
            passed += 1

    # Expressions outside the port, incomplete expressions and trailing port text
    # are not service-container ports. Numeric tunnel passwords must still report.
    for port in [':15432', '/${{ ports.db }}', ':5432/${{ ports.db }}',
                 ':${{ ports.db', ':${{ }}', ':${{ ports.db }}evil',
                 ':${{ ports.db }}:5432', ':prefix${{ ports.db }}',
                 ':${{ ports.db }}evil${{ ports.other }}']:
        check_url('127.0.0.1', port, 1)

    # A loopback-looking prefix or substring is never a loopback host exemption.
    for host in ['127.0.0.1.evil.com', 'localhost.example', '[::1].evil.com',
                 '::1.evil.com', '::1evil', '[::1]evil', 'evil-localhost',
                 '127.0.0.10', '127.1.0.1', '0.0.0.0', '::2', '[::2]',
                 '[2001:db8::1]', 'db.example.com']:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 1, user=user)
                check_url(host, port, 1, user=user, password='synthetic')

    # Encoded fixture lines can share a source-code line, but not an authority.
    fixture_url = 'redis://' + ':synthetic@localhost/0'
    remote_url = 'redis://' + ':<pw>@cache.example.com/0'
    for content, expected in [
        ('\\n'.join([fixture_url, fixture_url]), 0),
        ('\\n'.join([fixture_url, remote_url]), 1),
        ('"' + 'postgresql://' + 'user:<pw>@127.0.0.1:15432/app_test' + '"', 1),
        ('redis://' + ':synthetic@localhost:5432\\n@db.example.com/0', 1),
    ]:
        artifact.write_text(content + '\n')
        scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
        assert scan.returncode == expected, 'scan each URL authority independently without losing remote findings'
        assert not scan.stderr and (not scan.stdout if expected == 0 else scan.stdout == f'{artifact}:1: 带密码的 URL\n')
        passed += 1

    # Overrides replace the default whitelist, including an explicit empty list.
    config.write_text('secret_fixture_passwords = demo-fixture\n')
    check_url('localhost', ':5432', 0, password='demo-fixture')
    check_url('localhost', ':5432', 1, password='synthetic')
    check_url('localhost', ports[2], 0)
    config.write_text('secret_fixture_passwords =\n')
    check_url('localhost', ':5432', 1, password='synthetic')
    check_url('localhost', ports[2], 0)

    # Loopback exemptions apply only to password URLs, not custom secret formats.
    config.write_text('secret_pattern.redacted-test = <pw>\n')
    artifact.write_text('redis://' + ':<pw>@localhost:${{ ports.cache }}/0\n')
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 1 and scan.stdout == f'{artifact}:1: redacted-test\n' and not scan.stderr
    passed += 1
    print(f'PASS: {passed} scanner CLI checks (CI regression, exact loopbacks, remote/spoofed hosts, redaction, custom rules)')
PY
