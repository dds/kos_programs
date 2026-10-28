"""Fixed read-only Deck collectors; sent over SSH, never installed remotely."""
import re
import subprocess
from pathlib import Path, PurePosixPath

TEXT_LIMIT = 8 * 1024 * 1024
LOG_LIMIT = 2 * 1024 * 1024


def validate(request):
    if not isinstance(request, dict) or set(request) - {'action', 'boot', 'count', 'craft', 'path'}:
        raise ValueError('Unknown diagnostic request fields')
    if request.get('action') not in ('status', 'crash', 'logs', 'fetch'):
        raise ValueError('Unknown diagnostic action')
    if request.get('boot', 'previous') not in ('previous', 'current'):
        raise ValueError('Boot must be previous or current')
    count = request.get('count', 12)
    if type(count) is not int or not 1 <= count <= 50:
        raise ValueError('Log count must be between 1 and 50')
    if not re.fullmatch(r'[A-Za-z0-9_.-]{0,80}', request.get('craft', '')):
        raise ValueError('Craft filter must be a filename slug')
    path = request.get('path', '')
    if request['action'] == 'fetch':
        parts = path.split('/')
        if (len(parts) != 2 or any(part in ('', '.', '..') for part in parts)
                or not all(re.fullmatch(r'[A-Za-z0-9_.-]{1,180}', part) for part in parts)
                or not path.endswith('.log')):
            raise ValueError('Fetch requires flight/file.log or _diagnostics/file.log')
    elif path:
        raise ValueError('Only fetch accepts a log path')
    return request


def run_command(command):
    try:
        result = subprocess.run(command, capture_output=True, text=True, errors='replace', timeout=25)
        return dict(command=command, returncode=result.returncode,
                    stdout=result.stdout[:TEXT_LIMIT], stderr=result.stderr[:4000],
                    truncated=len(result.stdout) > TEXT_LIMIT)
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(command=command, error=str(error))


def read_tail(path, limit):
    try:
        size = path.stat().st_size
        with path.open('rb') as stream:
            data = stream.read(limit + 1)
            truncated = len(data) > limit
            if truncated:
                stream.seek(-limit, 2)
                data = stream.read(limit)
        return dict(bytes=max(size, len(data)), truncated=truncated,
                    text=data.decode('utf-8', errors='replace'))
    except OSError as error:
        return dict(error=str(error))


def archive_log(root, relative):
    path = (root / PurePosixPath(relative)).resolve(strict=True)
    if not path.is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError('Log path must stay within the flight archive')
    return path


def collect(request, home=None, run=run_command):
    validate(request)
    home = Path.home() if home is None else Path(home)
    action = request['action']
    result = dict(action=action, commands={}, files={})
    commands = result['commands']
    files = result['files']
    if action in ('status', 'crash'):
        commands['system'] = run(['uname', '-a'])
        commands['uptime'] = run(['uptime'])
        files['boot-id.txt'] = read_tail(Path('/proc/sys/kernel/random/boot_id'), 128)
    if action == 'status':
        commands['memory'] = run(['free', '-m'])
        commands['swap'] = run(['swapon', '--show', '--bytes'])
        commands['processes'] = run(['ps', '-eo', 'pid,ppid,comm,state,rss,vsz,wchan:32'])
        for name in ('meminfo', 'pressure/memory'):
            files[name.replace('/', '-') + '.txt'] = read_tail(Path('/proc') / name, 16000)
        for device in sorted(Path('/sys/class/drm').glob('card[0-9]*/device')):
            if not re.fullmatch(r'card[0-9]+', device.parent.name):
                continue
            for name in ('mem_info_vram_used', 'mem_info_vram_total',
                         'mem_info_gtt_used', 'mem_info_gtt_total', 'gpu_busy_percent'):
                files[device.parent.name + '-' + name + '.txt'] = read_tail(device / name, 1000)
    elif action == 'crash':
        boot = '-1' if request.get('boot', 'previous') == 'previous' else '0'
        commands['kernel'] = run(['journalctl', '-k', '-b', boot, '--no-pager', '-n', '20000'])
        commands['session'] = run(['journalctl', '-b', boot, '--no-pager', '-n', '2000',
            '--grep=amdgpu|ttm_|drm_exec|Out of memory|Killed process|Not enough memory|'
                   'gamescope.*(error|failed|fatal)|segfault|coredump'])
        game = home / 'Kerbal Space Program'
        paths = {
            'KSP.log': game / 'KSP.log',
            'Player-native.log': home / '.config/unity3d/Squad/Kerbal Space Program/Player.log',
            'Player-proton.log': home / '.local/share/Steam/steamapps/compatdata/220200/pfx/'
                'drive_c/users/steamuser/AppData/LocalLow/Squad/Kerbal Space Program/Player.log',
        }
        for name, path in paths.items():
            files[name] = read_tail(path, 256 * 1024)
    else:
        root = home / 'code/kos_programs/logs/archive'
        if action == 'fetch':
            relative = request['path']
            files['logs/' + relative] = read_tail(archive_log(root, relative), LOG_LIMIT)
        else:
            logs = []
            for path in root.glob('*/*.log'):
                if request.get('craft', '') not in path.as_posix():
                    continue
                try:
                    checked = archive_log(root, path.relative_to(root).as_posix())
                    stat = checked.stat()
                    logs.append(dict(path=path.relative_to(root).as_posix(),
                                     bytes=stat.st_size, mtime=stat.st_mtime))
                except (OSError, ValueError):
                    continue
            result['logs'] = sorted(logs, key=lambda item: item['mtime'], reverse=True)[:request.get('count', 12)]
    return result
