"""Small fixture snapshots only; never reads a real game or connects to a host."""
import hashlib
import json
import tarfile
import tempfile
from pathlib import Path
from unittest.mock import patch

import ksp_snapshot as capture


def fixture(folder):
    game = Path(folder) / 'game'
    (game / 'GameData/CustomParts').mkdir(parents=True)
    (game / 'GameData/NoIVA').mkdir()
    (game / 'saves/career').mkdir(parents=True)
    (game / 'Ships').mkdir()
    (game / 'saves/career/persistent.sfs').write_text('saved craft with kOS processor files')
    (game / 'GameData/CustomParts/engine.cfg').write_text('part config')
    (game / 'KSP_x64.exe').write_text('fixture executable, never run')
    (game / 'settings.cfg').write_text('graphics settings')
    (game / 'GameData/ModuleManager.ConfigCache').write_text('regenerable')
    (game / 'KSP.log').write_text('not needed for gameplay')
    archive = Path(folder) / 'archive'
    (archive / '.git').mkdir(parents=True)
    (archive / '.git/config').write_text('repository metadata')
    (archive / 'boot.ksm').write_bytes(b'compiled boot preserved')
    (game / 'Ships/Script').symlink_to(archive, target_is_directory=True)
    return game, archive, Path(folder) / 'snapshot.tar.gz'


def check_roundtrip():
    with tempfile.TemporaryDirectory() as folder, patch.object(capture, 'running_game', return_value=[]):
        game, archive, output = fixture(folder)
        manifest = capture.snapshot(game, output, archive)
        with tarfile.open(output) as bundle:
            names = bundle.getnames()
            assert 'Kerbal Space Program/saves/career/persistent.sfs' in names
            assert 'Kerbal Space Program/GameData/NoIVA' in names
            assert bundle.extractfile('Kerbal Space Program/Ships/Script/boot.ksm').read() == b'compiled boot preserved'
            assert bundle.extractfile('kOSArchive/boot.ksm').read() == b'compiled boot preserved'
            assert json.load(bundle.extractfile('snapshot-manifest.json')) == manifest
            assert not any('.git' in name or name.endswith('.log') or 'ConfigCache' in name for name in names)
            assert not any(member.issym() or member.islnk() for member in bundle.getmembers())
        checksum = output.with_name(output.name + '.sha256').read_text().split()[0]
        assert checksum == hashlib.sha256(output.read_bytes()).hexdigest()
        assert output.stat().st_mode & 0o777 == 0o600
        try:
            capture.snapshot(game, output, archive)
        except FileExistsError:
            pass
        else:
            raise AssertionError('overwrote snapshot')
    print('PASS: saves/full game/mods/empty folders/compiled kOS round-trip with flattened archive link, manifest and SHA256; caches and git excluded, private output never overwritten')


def check_admission_and_change_detection():
    with tempfile.TemporaryDirectory() as folder:
        game, archive, output = fixture(folder)
        with patch.object(capture, 'running_game', return_value=['KSP_x64.exe']):
            try:
                capture.snapshot(game, output)
            except RuntimeError:
                pass
            else:
                raise AssertionError('live source admitted without override')
        assert not output.exists()
        (game / 'outside').symlink_to(Path(folder).parent)
        try:
            capture.inventory(game)
        except ValueError:
            pass
        else:
            raise AssertionError('unexpected external link admitted')
        (game / 'outside').unlink()
        original = tarfile.TarFile.add
        def add(bundle, name, *args, **kwargs):
            original(bundle, name, *args, **kwargs)
            if str(name).endswith('persistent.sfs'):
                Path(name).write_text('changed during snapshot')
        with patch.object(capture, 'running_game', return_value=[]), patch.object(tarfile.TarFile, 'add', add):
            try:
                capture.snapshot(game, output)
            except RuntimeError:
                pass
            else:
                raise AssertionError('changed save accepted')
        assert not output.exists() and not output.with_name(output.name + '.sha256').exists()
    print('PASS: running game and unexpected external links reject; a save changing during capture invalidates and removes only the newly created incomplete bundle')


if __name__ == '__main__':
    check_roundtrip()
    check_admission_and_change_detection()
