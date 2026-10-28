#!/usr/bin/env python3
"""Create a private, self-contained KSP installation snapshot. No SSH or game control."""
import argparse
import hashlib
import io
import json
import os
import shutil
import socket
import subprocess
import tarfile
from datetime import datetime, timezone
from pathlib import Path

SKIP_DIRS = {'.git', '__pycache__', '.captures', 'logs', 'shadercache', 'crashes'}
SKIP_FILES = {'.ds_store', 'modulemanager.configcache', 'modulemanager.configsha',
              'modulemanager.physics', 'modulemanager.techtree'}


def running_game():
    try:
        result = subprocess.run(['ps', '-A', '-o', 'comm='], capture_output=True,
                                text=True, timeout=5, check=True)
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError('Cannot check whether KSP is running: ' + str(error)) from error
    names = {'ksp', 'ksp_x64', 'ksp_x64.exe', 'ksp.x86_64', 'ksp.exe'}
    return [line.strip() for line in result.stdout.splitlines()
            if Path(line.strip()).name.lower() in names]


def inventory(game, archive=None):
    roots = [(game.resolve(), 'Kerbal Space Program')]
    allowed = [game.resolve()]
    script = game / 'Ships/Script'
    if script.exists():
        allowed.append(script.resolve())
    if archive is not None:
        if not archive.is_dir():
            raise ValueError('kOS archive directory does not exist: ' + str(archive))
        allowed.append(archive.resolve())
        roots.append((archive.resolve(), 'kOSArchive'))
    entries, links = [], []

    def visit(path, name, ancestors):
        real = path.resolve(strict=True)
        if not any(real.is_relative_to(root) for root in allowed):
            raise ValueError('External symlink needs an explicit --archive-root: ' + str(path))
        if path.is_symlink():
            links.append(dict(path=name, target=str(real)))
        stat = path.stat()
        if path.is_dir():
            if real in ancestors:
                raise ValueError('Symlink directory cycle: ' + str(path))
            entries.append((path, name, stat, True))
            for child in sorted(path.iterdir()):
                lower = child.name.lower()
                if lower in SKIP_DIRS or lower in SKIP_FILES or lower.endswith(('.log', '.dmp', '.pyc')):
                    continue
                if path.name.lower() == 'ckan' and lower in ('downloads', 'cache'):
                    continue
                visit(child, name + '/' + child.name, ancestors | {real})
        elif path.is_file():
            entries.append((path, name, stat, False))
        else:
            raise ValueError('Unsupported special file: ' + str(path))

    for root, name in roots:
        visit(root, name, set())
    return entries, links


def snapshot(game, output, archive=None, allow_running=False):
    game, output = Path(game).expanduser().resolve(), Path(output).expanduser().absolute()
    archive = Path(archive).expanduser().resolve() if archive is not None else None
    if not (game / 'GameData').is_dir() or not (game / 'saves').is_dir():
        raise ValueError('Game root must contain GameData and saves')
    if not allow_running and running_game():
        raise RuntimeError('Save and quit KSP first; --allow-running explicitly permits a non-atomic live copy')
    if not str(output).endswith('.tar.gz'):
        raise ValueError('Output must end in .tar.gz')
    for root in (game, archive, (game / 'Ships/Script').resolve()):
        if root is not None and output.resolve().is_relative_to(root):
            raise ValueError('Write the snapshot outside the game and included kOS directories')
    checksum = output.with_name(output.name + '.sha256')
    if output.exists() or checksum.exists():
        raise FileExistsError('Refusing to overwrite an existing snapshot/checksum')
    entries, links = inventory(game, archive)
    size = sum(stat.st_size for _, _, stat, directory in entries if not directory)
    output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(output.parent).free < size + 128 * 1024 * 1024:
        raise RuntimeError('Not enough disk space for a conservative uncompressed-size estimate')
    names = {}
    for _, name, _, _ in entries:
        names.setdefault(name.casefold(), []).append(name)
    manifest = dict(format=1, created_utc=datetime.now(timezone.utc).isoformat(),
        source_host=socket.gethostname(), game_root=str(game), archive_root=str(archive or ''),
        live_copy=allow_running, uncompressed_bytes=size, entries=len(entries),
        mods=sorted(path.name for path in (game / 'GameData').iterdir() if path.is_dir()),
        links_dereferenced=links, case_collisions=[group for group in names.values() if len(group) > 1],
        exclusions=sorted(SKIP_DIRS | SKIP_FILES) + ['*.log', '*.dmp', '*.pyc', 'CKAN/downloads', 'CKAN/cache'],
        contents='Full platform-specific game, saves, ships, mods and settings; optional independent kOS archive')
    print(f'Snapshot: {len(entries)} entries, {size / 1024**3:.2f} GiB before compression', flush=True)
    created = False
    checksum_created = False
    try:
        with output.open('xb') as stream:
            created = True
            os.chmod(output, 0o600)
            with tarfile.open(fileobj=stream, mode='w|gz', dereference=True, compresslevel=1) as bundle:
                data = (json.dumps(manifest, indent=2) + '\n').encode()
                info = tarfile.TarInfo('snapshot-manifest.json')
                info.size, info.mode = len(data), 0o600
                bundle.addfile(info, io.BytesIO(data))
                for path, name, stat, directory in entries:
                    bundle.add(path, arcname=name, recursive=False)
                for path, _, before, directory in entries:
                    after = path.stat()
                    if not directory and (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise RuntimeError('Source changed during capture; retry after quitting KSP: ' + str(path))
                if not allow_running and running_game():
                    raise RuntimeError('KSP started during capture; retry after quitting it')
        digest = hashlib.sha256()
        with output.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        with checksum.open('x') as stream:
            checksum_created = True
            stream.write(digest.hexdigest() + '  ' + output.name + '\n')
    except BaseException:
        if created:
            output.unlink(missing_ok=True)
        if checksum_created:
            checksum.unlink(missing_ok=True)
        raise
    print('Saved: ' + str(output))
    print('SHA-256: ' + str(checksum))
    if manifest['case_collisions']:
        print('Use a case-sensitive destination filesystem; see case_collisions in the manifest.')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', type=Path, default=Path.home() / 'Kerbal Space Program')
    parser.add_argument('--output', type=Path, help='New .tar.gz file outside the game; never overwritten')
    parser.add_argument('--archive-root', type=Path, help='Also include a separate kOS archive/repository')
    parser.add_argument('--allow-running', action='store_true', help='Permit a live, non-atomic copy of disk state')
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output = args.output or Path.home() / 'ksp-snapshots' / ('ksp-' + stamp + '.tar.gz')
    try:
        snapshot(args.game, output, args.archive_root, args.allow_running)
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as error:
        parser.exit(1, 'Snapshot failed: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
