"""Source-driven diagnostic geometry, not kOS compilation or a flight test."""
import math
import re

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, mask, command_entrypoint_errors, function_body, dependency_tables, closure
from check_deorbit_geometry import Vec, Geo, fixture
from check_runtime_contracts import KString
from types import SimpleNamespace as NS

COMMAND = (ROOT/'cmd/deorbitcheck.ks').read_text()
LANDING_COMMAND = (ROOT/'cmd/landingcheck.ks').read_text()
WRITER = (ROOT/'lib/diagnostic_log.ks').read_text()
ks.SOURCES += '\n' + COMMAND + '\n' + WRITER


class Rotation:
    def __init__(self, degrees, axis):
        self.angle, self.axis = math.radians(degrees), axis/np.linalg.norm(axis)

    def __mul__(self, vec):
        cosine, sine = math.cos(self.angle), math.sin(self.angle)
        return Vec(vec*cosine + np.cross(self.axis,vec)*sine
                   + self.axis*np.dot(self.axis,vec)*(1-cosine))


def check_geometry():
    for spin in (40400, -40400, 0):
        env = fixture()
        world = env['SHIP'].BODY
        world.ROTATIONPERIOD = spin
        world.ANGULARVEL = Vec((0,0,2*math.pi/spin if spin else 0))
        def positionat(obj,ut):
            assert obj is env['SHIP'], 'Never subtract a future parent body position'
            angle = .001*ut
            return world.POSITION + Vec((62000*math.cos(angle),
                62000*math.sin(angle)*math.cos(.35),62000*math.sin(angle)*math.sin(.35)))
        env.update(POSITIONAT=positionat, ANGLEAXIS=Rotation,
                   VANG=lambda a,b: math.degrees(math.acos(np.clip(
                       np.dot(a,b)/np.linalg.norm(a)/np.linalg.norm(b),-1,1))))
        for name in ('lmGroundGeoAt','lmGroundPositionAt','lmGroundVelocityAt'):
            env[name] = lambda *args,name=name: ks.call(name,env,*args)
        impact_ut = 8040
        pos = positionat(env['SHIP'],impact_ut)-world.POSITION
        actual = Rotation(-(impact_ut-env['TIME'].SECONDS)*world.ANGULARVEL.MAG*180/math.pi,
                          world.ANGULARVEL)*pos if spin else pos
        geo = world.GEOPOSITIONOF(actual+world.POSITION)
        def check(): return ks.call('_deorbitCheckGeometry',env,geo,impact_ut)
        result = check()
        assert result['TR_NATIVE_GAP'] < .01 and result['TR_QUATERNION_GAP'] < .01,result
        assert np.linalg.norm(result['POSITION']-pos) < 1e-8
        # Deliberately corrupt one frame convention. The independent
        # quaternion measurement must expose, not share, that defect.
        original = env['lmGroundGeoAt']
        env['lmGroundGeoAt'] = lambda ut: Geo(original(ut).LAT,original(ut).LNG+20,world)
        result = check()
        assert result['TR_NATIVE_GAP'] > 15000 and result['TR_QUATERNION_GAP'] < .01,result
        env['lmGroundGeoAt'] = original
        geo = Geo(geo.LAT-10,geo.LNG+15,world)
        result = check()
        assert result['TR_NATIVE_GAP'] > 10000 and result['TR_QUATERNION_GAP'] > 10000,result
    print('PASS: native/quaternion comparisons agree for both spin directions and no spin; independent gaps expose a 20-degree frame defect and stale impact coordinates')


def check_read_only():
    for source in (COMMAND, LANDING_COMMAND, WRITER):
        clean = mask(source)
        if source != WRITER:
            assert not command_entrypoint_errors(source)
        assert not re.search(r'(?<!:)\b(?:ADD|REMOVE|LOCK|UNLOCK|STAGE|REBOOT|SHUTDOWN)\b(?!:)',clean)
        assert not re.search(r'\b(?:stateSet|stateRemove|missionOverrideUpdate|executeDeorbitNode|targetedDeorbitAt)\s*\(',clean)
        assert not re.search(r'\bSET\s+(?:WARP|THROTTLE|STEERING|SHIP:CONTROL)',clean)
    # Diagnostics do not become dependencies carried by every flight band.
    assert 'deorbitcheck' not in (ROOT/'lib/dependencies.ks').read_text()
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for roots in phases.values():assert 'diagnostic_log' not in closure(roots,deps)
    print('PASS: wrapped diagnostics and shared archive writer have no flight/node/mission-state mutation or added flight-band dependency')


def execute(source, env):
    def without_print(nodes):
        return [(s,without_print(yes),without_print(no)) for s,yes,no in nodes if not s.startswith('PRINT ')]
    try: ks.run(without_print(ks.parse(source)), env)
    except ks.Returned as result: return result.value


def check_archive_capture():
    writer = function_body(WRITER,'diagnosticArchiveLine').replace('LOG row TO dest.', 'append_row(row, dest).')
    ready = function_body(COMMAND,'_deorbitCheckArchiveReady')
    saved = function_body(WRITER,'diagnosticArchiveClose')
    path = '0:/logs/archive/_diagnostics/deorbitcheck_fixture.log'
    for links in ((True,True,True),(True,False,True),(False,False,False)):
        disk, reads = {}, []
        def append(row,dest):
            assert dest == path and env['HOMECONNECTION'].ISCONNECTED
            disk[dest] = disk.get(dest,'') + row + '\n'
        def open_file(dest):
            assert env['HOMECONNECTION'].ISCONNECTED
            reads.append(dest)
            return NS(READALL=NS(STRING=KString(disk[dest])))
        state = dict(READY=True,COMPLETE=True,PATH=path)
        env = dict(HOMECONNECTION=NS(ISCONNECTED=True), reportState=state,
                   label='STATS deorbit-check', TIME=NS(SECONDS='1000'),
                   append_row=append,EXISTS=lambda dest: dest in disk,OPEN=open_file)
        def write(state,row):
            env.update(reportState=state,row=row)
            return execute(writer,env)
        env['diagnosticArchiveLine'] = write
        for index,linked in enumerate(links):
            env['HOMECONNECTION'].ISCONNECTED = linked
            assert execute(ready,env) == linked
            assert write(state,f'metric {index}') == linked
        assert execute(saved,env) == all(links)
        assert state['COMPLETE'] == all(links)
        assert reads == ([path] if all(links) else [])
        assert all(dest.startswith('0:/logs/archive/_diagnostics/') for dest in disk)
    # A missing file/marker must never be announced as verified.
    env['HOMECONNECTION'].ISCONNECTED = True
    state['COMPLETE'] = True
    env['diagnosticArchiveLine'] = lambda *args: True
    disk.clear()
    assert execute(saved,env) is False
    disk[path] = 'partial snapshot\n'
    assert execute(saved,env) is False
    # Neither entry loads flight libraries before refusing a missing link.
    for source,name,guard in ((COMMAND,'_cmdDeorbitcheck','IF NOT _deorbitCheckArchiveReady()'),
                              (LANDING_COMMAND,'_cmdLandingcheck','IF NOT HOMECONNECTION:ISCONNECTED')):
        entry = function_body(source,name)
        assert entry.index(guard) < entry.index('RUNPATH(')
        assert 'diagnosticArchiveOpen(' in entry and 'diagnosticArchiveClose(' in entry
        assert 'STAGE:DELTAV:VACUUM' in entry and 'vesselLandingReserveAcc()' in entry
        assert 'eng:DECOUPLEDIN' in entry and 'eng:VISP' in entry
    assert '1:/run/deorbitcheck.log' not in COMMAND
    assert 'Verified snapshot in archive:' in WRITER
    # Capture creation stays archive-only and refuses even directory I/O offline.
    opening = function_body(WRITER,'diagnosticArchiveOpen')
    opening = opening.replace('ROUND(TIME:SECONDS,0)', '"1000"')
    for linked in (False,True):
        made = []
        env = dict(HOMECONNECTION=NS(ISCONNECTED=linked), prefix='landingcheck',
                   LEXICON=lambda *args: dict(zip(args[::2],args[1::2])), LIST=lambda *args: args,
                   slug=lambda:'RO9',EXISTS=lambda path:False,CREATEDIR=made.append)
        opened = execute(opening,env)
        assert opened['READY'] == linked and opened['COMPLETE'] == linked
        assert made == (['0:/logs','0:/logs/archive','0:/logs/archive/_diagnostics'] if linked else [])
        assert opened['PATH'] == ('0:/logs/archive/_diagnostics/landingcheck_RO9_1000.log' if linked else '')
    print('PASS: archive-only capture refuses a missing link, marks mid-capture loss incomplete even after reconnect, and verifies the completion row before reporting success')


def check_legacy_recovery():
    class Name(KString):
        def STARTSWITH(self,prefix): return self.casefold().startswith(prefix.casefold())
        def ENDSWITH(self,suffix): return self.casefold().endswith(suffix.casefold())
    source = function_body(COMMAND,'_recoverDeorbitReports').replace('LIST FILES IN items.', 'SET items TO list_files().')
    names = ['deorbitcheck_RO9_100.log','deorbitcheck.log','DEORBITCHECK_OTHER.LOG',
             'boot_012_core.log','deorbitcheck.txt','deorbitcheck_dir.log']
    for linked in (False,True):
        for legacy,label in (('0:/logs','archive'),('1:/run','local')):
            disk = {legacy+'/'+name:'old '+name for name in names[:-1]}
            old = dict(disk)
            dirs = {legacy}
            copies, cwd = [],['1:/']
            report_dir = '0:/logs/archive/_diagnostics'
            existing = report_dir+'/recovered_'+label+'_deorbitcheck.log'
            disk[existing] = 'preserved archive copy'
            def copy(src,dest):
                copies.append((src,dest))
                disk[dest] = disk[src]
            def list_files():
                assert cwd[0] == legacy
                return [NS(NAME=Name(name),ISFILE=name!=names[-1]) for name in names]
            env = dict(legacyDir=legacy,sourceLabel=label,reportDir=report_dir,
                       HOMECONNECTION=NS(ISCONNECTED=linked),EXISTS=lambda p: p in disk or p in dirs,
                       PATH=lambda: cwd[0],CD=lambda p: cwd.__setitem__(0,p),LIST=lambda: [],
                       list_files=list_files,COPYPATH=copy)
            execute(source,env)
            assert cwd[0] == '1:/'
            assert len(copies) == (2 if linked else 0),copies
            assert all(disk[p] == value for p,value in old.items())
            assert disk[existing] == 'preserved archive copy'
            assert all(dest.startswith(report_dir+'/recovered_'+label+'_') for _,dest in copies)
    print('PASS: old archive-root/local reports are recovered by name, with originals/existing copies and unrelated files preserved; no boot sweep needed')


if __name__ == '__main__':
    check_geometry()
    check_read_only()
    check_archive_capture()
    check_legacy_recovery()
