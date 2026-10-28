"""Read-only wrapper admission, fixed remote collectors and bounded local reports."""
import json
import runpy
import tempfile
from pathlib import Path
from unittest.mock import patch

import deck_diagnostics_remote as remote

ROOT = Path(__file__).resolve().parents[1]
WRAPPER = runpy.run_path(str(ROOT / 'scripts/deck-diagnostics'))


def check_rejected_requests():
    invalid = [dict(action='shell'), dict(action='reboot'), dict(action='status', command='id'),
               dict(action='crash', boot='-1; reboot'), dict(action='logs', count=0),
               dict(action='logs', count=51), dict(action='logs', count=True),
               dict(action='logs', craft='$(reboot)')]
    for path in ('../../etc/passwd', '/etc/passwd', 'flight/../../etc/passwd',
                 'flight/state.json', 'flight/file.log;reboot', 'flight/../a.log', 'file.log'):
        invalid.append(dict(action='fetch', path=path))
    for request in invalid:
        try:
            remote.collect(request, run=lambda _: (_ for _ in ()).throw(AssertionError('executed')))
        except ValueError:
            pass
        else:
            raise AssertionError(request)
    print('PASS: unknown actions, arbitrary commands, shell payloads, invalid limits and archive traversal reject before remote execution')


def check_archive_reads():
    with tempfile.TemporaryDirectory() as folder:
        home = Path(folder)
        root = home / 'code/kos_programs/logs/archive'
        flight = root / 'RO9_123'
        flight.mkdir(parents=True)
        log = flight / 'boot_001_core.log'
        log.write_text('first\nlast\n')
        (flight / 'state.json').write_text('not a flight log')
        outside = home / 'secret.log'
        outside.write_text('outside archive')
        (flight / 'escape.log').symlink_to(outside)
        listing = remote.collect(dict(action='logs', craft='RO9'), home)
        assert [item['path'] for item in listing['logs']] == ['RO9_123/boot_001_core.log']
        report = remote.collect(dict(action='fetch', path='RO9_123/boot_001_core.log'), home)
        assert report['files']['logs/RO9_123/boot_001_core.log']['text'] == 'first\nlast\n'
        try:
            remote.collect(dict(action='fetch', path='RO9_123/escape.log'), home)
        except ValueError:
            pass
        else:
            raise AssertionError('symlink escaped archive')
        tail = remote.read_tail(log, 5)
        assert tail['text'] == 'last\n' and tail['truncated']
        # sysfs/procfs report zero or page-sized stat lengths for tiny values.
        class Virtual:
            def stat(self):
                return type('Stat', (), dict(st_size=4096))()
            def open(self, mode):
                from io import BytesIO
                return BytesIO(b'1234\n')
        assert remote.read_tail(Virtual(), 1000)['text'] == '1234\n'
    print('PASS: only archive logs are listed/fetched, symlink escapes reject, oversized logs return marked tails and virtual GPU counters read correctly')


def check_fixed_collectors_and_transport():
    commands = []
    def run(command):
        commands.append(command)
        return dict(command=command, returncode=0, stdout='fixture\n', stderr='')
    with tempfile.TemporaryDirectory() as home:
        report = remote.collect(dict(action='crash', boot='previous'), home, run)
        assert ['journalctl', '-k', '-b', '-1', '--no-pager', '-n', '20000'] in commands
        assert all(command[0] in ('uname', 'uptime', 'journalctl') for command in commands)
        commands.clear()
        remote.collect(dict(action='status'), home, run)
        assert ['ps', '-eo', 'pid,ppid,comm,state,rss,vsz,wchan:32'] in commands
    ssh = WRAPPER['ssh_command']()
    assert ssh[-2:] == ['deck@10.200.26.154', 'python3 -']
    assert 'StrictHostKeyChecking=yes' in ssh and 'BatchMode=yes' in ssh
    # Exercise actual CLI transport/report creation without SSH or filesystem
    # changes on the Deck; the remote shell receives no interpolated request.
    done = type('Result', (), dict(returncode=0, stdout=json.dumps(report), stderr=''))()
    with tempfile.TemporaryDirectory() as directory:
        destination = Path(directory) / 'report'
        destination.mkdir()
        with patch('subprocess.run', return_value=done) as invoked, patch('tempfile.mkdtemp', return_value=str(destination)):
            assert WRAPPER['main'](['crash']) == 0
        assert invoked.call_args.args[0] == ssh
        payload = invoked.call_args.kwargs['input']
        assert 'collect(json.loads(' in payload
        assert (destination / 'report.json').exists() and (destination / 'kernel.log').read_text() == 'fixture\n'
    print('PASS: collectors use fixed read-only argv, strict pinned SSH, data on stdin and bounded locally saved reports; no settings, sudo, reboot or flight actions')


if __name__ == '__main__':
    check_rejected_requests()
    check_archive_reads()
    check_fixed_collectors_and_transport()
