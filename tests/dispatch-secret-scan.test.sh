#!/usr/bin/env bash
# Exercise the scanner CLI with synthetic URLs, never real credentials.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
exec python3 -B - <<'PY'
import json
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
    # Synthetic service-container URL with a default fixture password.
    artifact.write_text('TEST_DATABASE_URL: postgresql://' + "postgres:synthetic@127.0.0.1:${{ job.services.postgres.ports['5432'] }}/app_test\n")
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 0 and not scan.stdout and not scan.stderr, 'CI loopback URL must not be reported as a credential'
    print('PASS: allowlisted CI loopback URL is clean', flush=True)

    # Replay all review rounds through the public CLI. Expectations come
    # from the whole-URL contract, not from the scanner's matching expressions.
    corpus = json.loads((Path(os.environ['ROOT']) / 'tests/dispatch-secret-scan-review.json').read_text())
    failures = []
    for label, expected, content in corpus['cases']:
        artifact.write_text(content)
        scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
        if scan.returncode != expected:
            failures.append(f'{label}: expected {expected}, got {scan.returncode}')
        assert not scan.stderr, f'{label}: unexpected scan error'
        # Only positions and kinds may be printed, including multiline inputs.
        for finding in scan.stdout.splitlines():
            position, kind = finding.rsplit(': ', 1)
            path, line = position.rsplit(':', 1)
            assert path == str(artifact) and line.isdigit() and kind in ('带密码的 URL', '私钥'), label
        assert bool(scan.stdout) == (scan.returncode == 1), label
    assert not failures, 'review corpus mismatches:\n' + '\n'.join(failures)
    print(f"PASS: {len(corpus['cases'])} review corpus cases", flush=True)

    passed = 1 + len(corpus['cases'])
    def check_url(host, port, expected, user='postgres', scheme='postgresql', password='<pw>', query='', dbname='app_test'):
        global passed
        url = f'{scheme}://{user}:{password}@{host}{port}/{dbname}{query}'
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

    # All ports require a fixture password, including complete CI expressions.
    ports = ['', ':5432', ":${{ job.services.postgres.ports['5432'] }}"]
    loopbacks = ['127.0.0.1', '[::1]', 'localhost', 'LOCALHOST']
    for host in loopbacks:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 1, user=user)
                check_url(host, port, 0, user=user, password='synthetic')

    # Only literal safe query names and simple values are exempt. Everything
    # outside the allowlisted DB/query shape is reported, not just target keys.
    target_queries = [
        '?host=db.prod.example.com',
        '?hostaddr=203.0.113.7',
        '?sslmode=disable&host=db.prod.example.com',
        '?sslmode=disable&hostaddr=203.0.113.7',
        '?HOST=db.prod.example.com',
        '?application_name=probe&HoStAdDr=203.0.113.7',
        '?host=', '?hostaddr=', '?host=localhost',
        '?application_name=host=db.prod.example.com',
        '?myhost=db.prod.example.com', '?hostaddress=203.0.113.7',
        '/host=db.prod.example.com', '/&host=db.prod.example.com',
        '#?host=db.prod.example.com', '?sslmode=disable#&host=db.prod.example.com',
        '?h%6Fst=db.prod.example.com', '?%68ost%61ddr=203.0.113.7',
        '?sslmode=disable;host=db.prod.example.com',
        '?SSLMODE=disable', '?application%5Fname=ci', '?sslmode=%64isable',
        '?sslmode=disable&', '?sslmode=disable&&connect_timeout=1',
        '?sslmode', '?', '?application_name=a/b', '?application_name=${{ env.NAME }}',
        '?schema=public', '?charset=utf8mb4', '?TimeZone=UTC', '?authSource=admin',
    ]
    harmless_queries = [
        '?sslmode=disable', '?application_name=hostx', '?connect_timeout=10',
        '?sslmode=disable&application_name=ci&connect_timeout=1',
        '?application_name=probe_1.2-3', '?application_name=',
        '?connect_timeout=&sslmode=', '?sslmode=disable&sslmode=require',
    ]
    for host in loopbacks:
        for port, password in [('', 'synthetic'), (':5432', 'postgres'),
                               (ports[2], 'postgres'), (ports[2], 'synthetic')]:
            for query in target_queries:
                check_url(host, port, 1, password=password, query=query)
            for query in harmless_queries:
                check_url(host, port, 0, password=password, query=query)

    # DB names and URL terminators are part of the whitelist. Bare ::1 is
    # deliberately rejected; bracketed IPv6 is the only IPv6 fixture shape.
    for port, password in [('', 'synthetic'), (':5432', 'postgres'), (ports[2], 'synthetic')]:
        for dbname in ['', '.', 'app.test', 'app%5Ftest', 'app/test', '${{ env.DB_NAME }}']:
            check_url('localhost', port, 1, password=password, dbname=dbname)
        check_url('LOCALHOST', port, 0, password=password, dbname='DB-1_2')
        check_url('::1', port, 1, password=password)
        for tail in ['#', '@', ',', ';', '\\', '.', '/', '%20', '?sslmode=disable#',
                     '/${{ env.DB_NAME }}?host=db.example.com']:
            check_url('localhost', port, 1, password=password, query=tail)
    for port in [':', ':abc', ':12x', ':${{ ports.db }}${{ ports.other }}',
                 ':${{ ports.db }}evil', ':${{ }}', ':${{ a}}b }}']:
        check_url('localhost', port, 1, password='synthetic')
    check_url('127.0.0.1', ports[2], 0, password='synthetic', query='?sslmode=disable')
    check_url('localhost', ':0005432', 0, password='synthetic')

    # Quote/line boundaries are checked even with an allowlisted password.
    # Unquoted whitespace or quotes cannot hide a later target override.
    later_target = 'postgresql://' + 'db.example.com/app_test?host=db.prod.example.com'
    for port in [':5432', ports[2]]:
        for query in ['', '?sslmode=disable']:
            url = 'postgresql://' + f'app_test:synthetic@localhost{port}/app_test{query}'
            boundaries = [(url + tail, expected) for tail, expected in [
                ('', 0), ('  \t', 0), (' # fixture comment', 0), ('\t# comment', 0),
                ('#comment', 1), (' #comment\n', 0),
                (' ?host=db.example.com', 1), ('\t?host=db.example.com', 1),
                ("'?host=db.example.com", 1), ('"?host=db.example.com', 1),
                (' ?sslmode=disable&host=db.example.com', 1),
                (' ' + later_target, 1), (',', 1), (';', 1), ('}', 1),
            ]]
            for quote in ["'", '"']:
                other = '"' if quote == "'" else "'"
                boundaries.extend([
                    ('TEST_DATABASE_URL: ' + quote + url + quote, 0),
                    ('TEST_DATABASE_URL: ' + quote + url + other, 1),
                    ('TEST_DATABASE_URL: ' + quote + url, 1),
                    ('TEST_DATABASE_URL: ' + quote + url + ' ?host=db.example.com' + quote, 1),
                    ('TEST_DATABASE_URL: ' + quote + url + quote + ' # comment', 0),
                    ('TEST_DATABASE_URL: ' + quote + url + quote + ',}', 0),
                    ('TEST_DATABASE_URL: ' + quote + url + quote + ']', 0),
                    ('TEST_DATABASE_URL: ' + quote + url + quote + '?host=db.example.com', 1),
                    (quote + url + quote + ' ' + later_target, 0),
                ])
            boundaries.extend([
                (json.dumps({'url': url}), 0),
                ('`' + url + '`', 1), ('[fixture](' + url + ')', 1),
                ('<' + url + '>', 1),
                ('redis://' + ':synthetic@localhost:6379', 1),
                ('postgresql://' + 'app:synthetic@localhost:5432', 1),
            ])
            for content, expected in boundaries:
                artifact.write_text(content + '\n')
                scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
                assert scan.returncode == expected, f'URL boundary: expected {expected}, got {scan.returncode}'
                assert not scan.stderr
                assert scan.stdout == (f'{artifact}:1: 带密码的 URL\n' if expected else '')
                passed += 1

    # Keep the whole-URL port shape restriction, not a template-based exemption.
    for port in ['/${{ ports.db }}', ':5432/${{ ports.db }}',
                 ':${{ ports.db', ':${{ }}', ':${{ ports.db }}evil',
                 ':${{ ports.db }}:5432', ':prefix${{ ports.db }}',
                 ':${{ ports.db }}evil${{ ports.other }}']:
        check_url('127.0.0.1', port, 1, password='synthetic')

    # A loopback-looking prefix or substring is never a loopback host exemption.
    for host in ['127.0.0.1.evil.com', 'localhost.example', '[::1].evil.com',
                 '::1.evil.com', '::1evil', '[::1]evil', 'evil-localhost',
                 '127.0.0.10', '127.1.0.1', '0.0.0.0', '::2', '[::2]',
                 '[2001:db8::1]', 'db.example.com']:
        for port in ports:
            for user in ['postgres', '']:
                check_url(host, port, 1, user=user)
                check_url(host, port, 1, user=user, password='synthetic')

    # A literal backslash is not a URL boundary, even for encoded newlines.
    fixture_url = 'redis://' + ':synthetic@localhost/0'
    remote_url = 'redis://' + ':<pw>@cache.example.com/0'
    for content, expected in [
        ('\\n'.join([fixture_url, fixture_url]), 1),
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
    check_url('localhost', ports[2], 0, password='demo-fixture')
    check_url('localhost', ports[2], 1, password='synthetic')
    check_url('localhost', ports[2], 1)
    config.write_text('secret_fixture_passwords =\n')
    check_url('localhost', ':5432', 1, password='synthetic')
    check_url('localhost', ports[2], 1, password='synthetic')
    check_url('localhost', ports[2], 1)

    # Loopback exemptions apply only to password URLs, not custom secret formats.
    config.write_text('secret_pattern.redacted-test = synthetic\n')
    artifact.write_text('redis://' + ':synthetic@localhost:${{ ports.cache }}/0\n')
    scan = subprocess.run(['sh', str(scanner), str(artifact)], env=env, capture_output=True, text=True)
    assert scan.returncode == 1 and scan.stdout == f'{artifact}:1: redacted-test\n' and not scan.stderr
    passed += 1
    print(f'PASS: {passed} scanner CLI checks (CI regression, exact loopbacks, remote/spoofed hosts, redaction, custom rules)')
PY
