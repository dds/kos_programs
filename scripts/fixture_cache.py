"""Verified local check results, invalidated by observed inputs; never flight state."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import stat
import sys
import tempfile
import time

SCHEMA = 1
_STAT, _LSTAT = os.stat, os.lstat


def absolute(path):
    return os.path.abspath(os.fsdecode(os.fspath(path)))


def within(path, directory):
    return path == directory or path.startswith(directory + os.sep)


def metadata(path, follow=True):
    try:
        item = (_STAT if follow else _LSTAT)(path)
        return [item.st_mode, item.st_size, item.st_mtime_ns, item.st_ctime_ns,
                item.st_ino, item.st_dev]
    except FileNotFoundError:
        return None


def fingerprint(kind, path):
    if kind in ('probe-stat', 'probe-lstat'):
        follow = kind == 'probe-stat'
        item = metadata(path, follow)
        if item is None:
            return None
        link = os.readlink(path) if not follow and stat.S_ISLNK(item[0]) else None
        return [item[0], link]
    if kind in ('stat', 'lstat'):
        return metadata(path, kind == 'stat')
    if kind == 'directory':
        try:
            return sorted(os.listdir(path))
        except FileNotFoundError:
            return None
    if kind == 'file':
        try:
            item = _STAT(path)
            if stat.S_ISDIR(item.st_mode):
                return 'directory'
            if not stat.S_ISREG(item.st_mode):
                raise ValueError('non-regular input')
            with open(path, 'rb') as stream:
                return hashlib.file_digest(stream, 'sha256').hexdigest()
        except FileNotFoundError:
            return None
    raise ValueError('unknown input kind')


class Inputs:
    """Trace reads and filesystem probes, excluding artifacts created by the test.

    Hooks stay installed but dormant after exit. Workers run one check file,
    so no later check can inherit either hooks or mutated fixture globals.
    """
    def __init__(self):
        self.active = self.busy = False
        self.inputs = {}
        self.files = set()
        self.created_files, self.created_dirs = set(), set()
        self.reason = ''

    def generated(self, path):
        return path in self.created_files or any(within(path, parent) for parent in self.created_dirs)

    def remember(self, kind, path, value=None, supplied=False):
        if isinstance(path, int):
            self.reason = 'file-descriptor-input'
            return
        path = absolute(path)
        if self.generated(path):
            return
        key = (kind, path)
        if key not in self.inputs:
            self.inputs[key] = value if supplied else fingerprint(kind, path)

    def audit(self, event, args):
        if not self.active or self.busy:
            return
        self.busy = True
        try:
            if event in ('subprocess.Popen', 'os.system', 'os.fork', 'socket.connect', 'socket.bind'):
                self.reason = 'external-operation:' + event
            elif event == 'os.mkdir':
                path = absolute(args[0])
                if metadata(path) is None:
                    self.created_dirs.add(path)
            elif event == 'open':
                path, mode, flags = args
                if isinstance(path, int):
                    self.reason = 'file-descriptor-input'
                    return
                path = absolute(path)
                writes = flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC)
                if writes:
                    if metadata(path) is None:
                        self.created_files.add(path)
                    elif not self.generated(path):
                        self.reason = 'writes-existing-input'
                elif not self.generated(path):
                    self.files.add(path)
                    self.remember('stat', path)
                    if path.endswith('.pyc'):
                        source = importlib.util.source_from_cache(path)
                        self.files.add(source)
                        self.remember('stat', source)
            elif event == 'import' and args[1]:
                self.files.add(absolute(args[1]))
                self.remember('stat', args[1])
            elif event in ('os.listdir', 'os.scandir'):
                self.remember('directory', args[0] if args and args[0] is not None else os.getcwd())
        except (OSError, TypeError, ValueError):
            self.reason = 'untracked-filesystem-input'
        finally:
            self.busy = False

    def _stat(self, path, *args, follow=True, **kwargs):
        original = _STAT if follow else _LSTAT
        try:
            return original(path, *args, **kwargs)
        finally:
            if self.active and not self.busy:
                self.busy = True
                try:
                    if args or set(kwargs)-{'follow_symlinks'}:
                        self.reason = 'nonstandard-stat-input'
                    actual_follow = follow and kwargs.get('follow_symlinks', True)
                    kind = 'stat' if actual_follow else 'lstat'
                    if self._path_probe():
                        kind = 'probe-' + kind
                    self.remember(kind, path)
                except (OSError, TypeError, ValueError):
                    self.reason = 'untracked-stat-input'
                finally:
                    self.busy = False

    def _path_probe(self):
        frame = sys._getframe(1)
        while frame and frame.f_globals.get('__name__') == __name__:
            frame = frame.f_back
        while frame:
            module = frame.f_globals.get('__name__', '')
            if not (module.startswith('pathlib') or module in ('posixpath', 'ntpath', 'genericpath')):
                break
            if frame.f_code.co_name in ('exists','lexists','isfile','isdir','islink','is_file','is_dir','is_symlink',
                                        'resolve','realpath','_realpath','_joinrealpath'):
                return True
            frame = frame.f_back
        return False

    def __enter__(self):
        sys.addaudithook(self.audit)
        self.previous_stat, self.previous_lstat = os.stat, os.lstat
        os.stat = lambda path, *args, **kwargs: self._stat(path, *args, **kwargs)
        os.lstat = lambda path, *args, **kwargs: self._stat(path, *args, follow=False, **kwargs)
        self.active = True
        return self

    def __exit__(self, *args):
        self.active = False
        os.stat, os.lstat = self.previous_stat, self.previous_lstat

    def finish(self):
        # Importers may read a valid .pyc rather than opening its source.
        # Include every loaded module's source/native library as well.
        for module in tuple(sys.modules.values()):
            path = getattr(module, '__dict__', {}).get('__file__')
            if not path:
                continue
            try:
                path = os.fsdecode(os.fspath(path))
                if path.endswith('.pyc'):
                    path = importlib.util.source_from_cache(path)
                path = absolute(path)
                if not self.generated(path):
                    self.files.add(path)
            except (TypeError, ValueError):
                self.reason = 'unknown-import-input'
        records = []
        try:
            for (kind, path), observed in sorted(self.inputs.items()):
                if fingerprint(kind, path) != observed:
                    self.reason = 'input-changed-during-check'
                records.append(dict(kind=kind, path=path, value=observed))
            for path in sorted(self.files):
                if not self.generated(path):
                    records.append(dict(kind='file', path=path, value=fingerprint('file', path)))
        except (OSError, ValueError):
            self.reason = 'unreadable-input'
        return dict(cacheable=not self.reason, reason=self.reason, inputs=records)


def context(root, env):
    digest = hashlib.sha256()
    details = [SCHEMA, str(root), sys.version, sys.executable, repr(sys.flags),
               platform.platform(), sorted(env.items())]
    digest.update(json.dumps(details, sort_keys=True).encode())
    # Runner changes invalidate all results. Other Python sources are covered
    # by each worker's complete imported-module/read manifest.
    for name in ('run_checks.py', 'fixture_cache.py'):
        path = Path(__file__).parent/name
        digest.update(str(path).encode())
        digest.update(path.read_bytes())
    # Import finders may populate these directory caches before tracing starts.
    # Catch new optional modules and changes in search-path precedence as well.
    search = {str(root/'scripts'), *map(str, sys.path)}
    for module in tuple(sys.modules.values()):
        search.update(map(str, getattr(module, '__dict__', {}).get('__path__', ())))
    for path in sorted(map(absolute, search)):
        digest.update(json.dumps([path, os.path.realpath(path),
            fingerprint('directory', path) if os.path.isdir(path) else metadata(path)],
            sort_keys=True).encode())
    digest.update(fingerprint('file', sys.executable).encode())
    return digest.hexdigest()


class Results:
    def __init__(self, directory, context_key):
        self.directory, self.context_key = Path(directory), context_key
        self.directory.mkdir(parents=True, exist_ok=True)
        # Do not trust a read-only cache that cannot revoke an older pass.
        with tempfile.NamedTemporaryFile(dir=self.directory):
            pass
        self.fingerprints = {}

    def path(self, check):
        name = hashlib.sha256(str(check).encode()).hexdigest()
        return self.directory/(name+'.json')

    def lookup(self, check):
        try:
            record = json.loads(self.path(check).read_text())
            if record['schema'] != SCHEMA or record['context'] != self.context_key:
                return None
            row = record['row']
            if record['check'] != str(check) or row['returncode'] != 0 or row['module'] != check.name:
                return None
            for item in record['inputs']:
                kind, path = item['kind'], item['path']
                # Stat once per lookup; digest a shared library only once while
                # its identity/metadata stay unchanged during this invocation.
                key = (kind, path, tuple(metadata(path, kind not in ('lstat','probe-lstat')) or ()))
                if key not in self.fingerprints:
                    self.fingerprints[key] = fingerprint(kind, path)
                if self.fingerprints[key] != item['value']:
                    return None
            return dict(row, cached=True, wall_seconds=0, verified_at=record['verified_at'])
        except (OSError, KeyError, TypeError, ValueError):
            return None

    def save(self, check, row):
        proof = row.pop('input_proof', {})
        row['cache_skip_reason'] = proof.get('reason', '')
        if row['returncode'] != 0 or not proof.get('cacheable'):
            self.discard(check)
            return
        record = dict(schema=SCHEMA, context=self.context_key, check=str(check),
                      row=row, inputs=proof['inputs'], verified_at=time.time())
        with tempfile.NamedTemporaryFile(mode='w', dir=self.directory, delete=False) as stream:
            temp = Path(stream.name)
            json.dump(record, stream)
        os.replace(temp, self.path(check))

    def discard(self, check):
        self.path(check).unlink(missing_ok=True)
