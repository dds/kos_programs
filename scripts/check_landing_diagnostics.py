"""Automatic flight-recorder buffers/export gates, not KSP I/O timing proof."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, closure, dependency_tables
from check_landing_divert import fixture as divert_fixture

SOURCE = (ROOT/'lib/landing_diagnostics.ks').read_text()


class Text(str):
    # KerboScript concatenates scalar values into strings. Keep this behavior
    # local to these logging fixtures; do not change the physics interpreter.
    def __add__(self, other): return Text(str(self)+str(other))
    @property
    def LENGTH(self): return len(self)
    def CONTAINS(self, other): return other in self


class Items(list):
    @property
    def LENGTH(self): return len(self)
    def ADD(self, item): self.append(item)
    def REMOVE(self, index): self.pop(index)


class Lex(dict):
    def HASKEY(self, key): return key in self


def fixture():
    env,ctx,*_=divert_fixture(gravity=.491, radius=60000)
    ctx.update(STATE='COAST',TARGET_THROTTLE=0,RESERVE_ACC=2.74,
               DISCARD_PENDING=False,STAGE_UNTIL=0,DIVERT_SEARCH=Lex())
    env['SHIP'].BODY.NAME='Minmus'
    env['SHIP'].BODY.MU=1.7658e9
    env['SHIP'].BODY.ROTATIONPERIOD=40400
    env['SHIP'].NAME='RO9'
    env['SHIP'].MASS=1.287
    env['SHIP'].THRUST=0
    env['SHIP'].CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
    disk,dirs,operations={},{},[]
    def linked(op):
        assert env['HOMECONNECTION'].ISCONNECTED, op
        operations.append(op)
    def exists(path):
        linked(('exists',path))
        return path in disk or path in dirs
    def mkdir(path):
        linked(('mkdir',path))
        dirs[path]=True
    def append(payload,path):
        linked(('write',path))
        disk[path]=Text(disk.get(path,'')+payload+'\n')
    def opening(path):
        linked(('read',path))
        return NS(READALL=NS(STRING=disk[path]))
    def copy(src,dest):
        linked(('copy',dest))
        disk[dest]=disk[src]
    env.update(LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),
               fixture_text=Text,CHAR=lambda n:Text(chr(n)),MOD=lambda a,b:a%b,
               STAGE=NS(NUMBER=1), HOMECONNECTION=NS(ISCONNECTED=True),
               slug=lambda:Text('RO9'),bootLogName=lambda:Text('boot_012_core.log'),
               EXISTS=exists,CREATEDIR=mkdir,append_payload=append,OPEN=opening,COPYPATH=copy,
               flightLogPath=lambda:Text('1:/run/logs/boot_012_core.log'),
               _landingBrakeGateInfo=lambda c:dict(V_ETA=90,H_ETA=90))
    disk['1:/run/logs/boot_012_core.log']=Text('STATS existing flight log\n')
    def invoke(name,*args):
        body=function_body(SOURCE,name).replace('LOG payload TO dest.','append_payload(payload,dest).')
        # Preserve actual source branches and operations, adding only the
        # VM's scalar/string concatenation semantics and disk adapters.
        body=re.sub(r'"[^"\n]*"',lambda m:'fixture_text('+m[0]+')',body)
        local=dict(env,**dict(zip(re.findall(r'PARAMETER (\w+)',body),args)))
        try:ks.run(ks.parse(body),local)
        except ks.Returned as result:return result.value
    for name in re.findall(r'GLOBAL FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:invoke(name,*args)
    env['landingDiagnosticStart'](ctx)
    return env,ctx,disk,operations


def check_buffer_and_hover():
    env,ctx,disk,ops=fixture()
    record=env['landingDiagnosticRecord']
    for index in range(100):record(ctx,Text('row'+str(index)))
    capture=ctx['DIAGNOSTIC']
    assert len(capture['ROWS'])==32 and capture['DROPPED']==68
    assert capture['ROWS'][0]=='row68' and capture['BYTES']==sum(map(len,capture['ROWS']))
    for _ in range(10):record(ctx,Text('x'*3000))
    assert capture['BYTES']<=8000 and len(capture['ROWS'])<=32
    assert capture['BYTES']==sum(map(len,capture['ROWS']))
    ctx.update(STATE='APPROACH',height=260,TARGET_THROTTLE=.18)
    env['SHIP'].THRUST=.35
    env['SHIP'].CONTROL.MAINTHROTTLE=.18
    for now in (0,.05,1,2,2.05,4):
        env['TIME'].SECONDS=now
        env['landingDiagnosticHud'](ctx,Text('APPROACH d=781 bottom=260 hs=0/4 vs=0/-0.3'))
        assert not env['landingDiagnosticTick'](ctx)
    controls=[row for row in capture['CONTROL_ROWS'] if ' control ' in row]
    assert len(controls)==3 and all('vs=0/-0.3' in row and 'state=APPROACH' in row for row in controls)
    retained=list(capture['ROWS'])
    for now in range(6,206,2):
        env['TIME'].SECONDS=now
        env['landingDiagnosticHud'](ctx,Text('APPROACH d=781 bottom=260 hs=0/4 vs=0/-0.3'))
    assert capture['ROWS']==retained
    assert len(capture['CONTROL_ROWS'])<=32 and capture['CONTROL_BYTES']<=8000
    assert not ops and ctx['TARGET_THROTTLE']==.18
    print('PASS: recorder bounds rows/characters with eviction counts and captures a 260m approach hold every two seconds without archive I/O or changing thrust')


def check_export_gates():
    scenarios=('burn','approach','align','requested','physical','pilot','raw','stage',
               'discard','gate','horizontal-gate','invalid-gate','abort','offline','cadence','safe')
    for scenario in scenarios:
        env,ctx,disk,ops=fixture()
        if scenario=='burn':ctx['STATE']='BRAKING_BURN'
        if scenario=='approach':ctx['STATE']='APPROACH'
        if scenario=='align':ctx['STATE']='BRAKE_ALIGN'
        if scenario=='requested':ctx['TARGET_THROTTLE']=.1
        if scenario=='physical':env['SHIP'].THRUST=.01
        if scenario=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if scenario=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if scenario=='stage':ctx['STAGE_UNTIL']=1
        if scenario=='discard':ctx['DISCARD_PENDING']=True
        if scenario in ('gate','invalid-gate'):
            env['_landingBrakeGateInfo']=lambda c:dict(V_ETA=59.9 if scenario=='gate' else float('nan'),H_ETA=90)
        if scenario=='horizontal-gate':env['_landingBrakeGateInfo']=lambda c:dict(V_ETA=90,H_ETA=59.9)
        if scenario=='abort':env['ABORT']=True
        if scenario=='offline':env['HOMECONNECTION'].ISCONNECTED=False
        if scenario=='cadence':ctx['DIAGNOSTIC']['LAST_ATTEMPT']=0
        before=dict(ctx)
        assert bool(env['landingDiagnosticTick'](ctx))==(scenario=='safe'),scenario
        assert bool(ops)==(scenario=='safe'),scenario
        assert ctx['STATE']==before['STATE'] and ctx['TARGET_THROTTLE']==before['TARGET_THROTTLE']
        if scenario=='safe':
            saved=disk[ctx['DIAGNOSTIC']['PATH']]
            assert 'schema=1' in saved and 'finished=False' in saved
            assert not ctx['DIAGNOSTIC']['ROWS'] and ctx['DIAGNOSTIC']['BYTES']==0
            assert not any(op[0] in ('read','copy') for op in ops)
    print('PASS: exports require physical/pilot/raw/requested zero, no staging/abort, COAST, valid >=60s gate, link and 15s cadence; no control changes or in-flight readback/copy')


def check_completion_and_link_loss():
    env,ctx,disk,ops=fixture()
    tick=env['landingDiagnosticTick']
    assert tick(ctx)
    path=ctx['DIAGNOSTIC']['PATH']
    earlier=disk[path]
    env['TIME'].SECONDS=20
    env['HOMECONNECTION'].ISCONNECTED=False
    env['landingDiagnosticRecord'](ctx,Text('retained offline row'))
    assert not tick(ctx) and disk[path]==earlier and ctx['DIAGNOSTIC']['ROWS']
    env['HOMECONNECTION'].ISCONNECTED=True
    ctx['STATE']='TOUCHDOWN'
    assert tick(ctx,True)
    assert disk[path].startswith(earlier) and 'retained offline row' in disk[path]
    assert 'finished=True' in disk[path] and disk[path+'.boot.log'].startswith('STATS existing')
    assert ('read',path) in ops and ('copy',path+'.boot.log') in ops
    # A cleanup request still cannot bypass actual cutoff or a missing link.
    for failure in ('thrust','raw','pilot','link'):
        env,ctx,disk,ops=fixture()
        if failure=='thrust':env['SHIP'].THRUST=.01
        if failure=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if failure=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if failure=='link':env['HOMECONNECTION'].ISCONNECTED=False
        assert not env['landingDiagnosticTick'](ctx,True) and not ops
    env,ctx,disk,ops=fixture()
    append=env['append_payload']
    def disconnect(payload,path):
        append(payload,path)
        env['HOMECONNECTION'].ISCONNECTED=False
    env['append_payload']=disconnect
    assert not env['landingDiagnosticTick'](ctx) and ctx['DIAGNOSTIC']['ROWS']
    env['HOMECONNECTION'].ISCONNECTED=True
    env['append_payload']=append
    env['TIME'].SECONDS=20
    assert env['landingDiagnosticTick'](ctx,True)
    env,ctx,disk,ops=fixture()
    env['OPEN']=lambda path:NS(READALL=NS(STRING=Text('missing checkpoint')))
    assert not env['landingDiagnosticTick'](ctx,True) and ctx['DIAGNOSTIC']['ROWS']
    assert not any(op[0]=='copy' for op in ops)
    print('PASS: offline rows survive in memory, reconnect appends checkpoints without replacing reports, and verified post-cutoff completion copies the flight log; final export still respects physical cutoff/link')


def check_candidate_capture_and_wiring():
    env,ctx,disk,ops=fixture()
    site=Lex(OK=False,REASON='terrain-grade',GRADE=.3,ELEVATION=3000,
             TERRAIN=Items((3002,2998,3004,2996)),DIST=100,TRANSIT=70,SUN=-999,KERBIN=-999)
    env['landingDiagnosticSample'](ctx,site,1,2,False,5)
    assert 'neighbors20m=3002,2998,3004,2996' in ctx['DIAGNOSTIC']['ROWS'][-1]
    assert 'reason=terrain-grade' in ctx['DIAGNOSTIC']['ROWS'][-1]
    ctx['DIVERT_SEARCH']=Lex(CHECKED=2)
    site.update(REASON='reachability',GRADE=-1,TERRAIN=Items())
    count=len(ctx['DIAGNOSTIC']['ROWS'])
    env['landingDiagnosticSample'](ctx,site,1,2,False,5)
    assert len(ctx['DIAGNOSTIC']['ROWS'])==count
    ctx['DIVERT_SEARCH']['CHECKED']=10
    env['landingDiagnosticSample'](ctx,site,1,2,False,5)
    assert 'neighbors20m=unmeasured' in ctx['DIAGNOSTIC']['ROWS'][-1] and not ops
    main=function_body((ROOT/'lib/landing_main.ks').read_text(),'landExecute')
    assert main.index('landingDiagnosticStart(ctx)')<main.index('landingReviewReachableSite(ctx)')
    assert main.index('_landingGuidanceTick(ctx)')<main.index('landingDiagnosticTick(ctx)')<main.index('WAIT tickRate')
    assert 'vesselLandingCleanup().\n        landingDiagnosticTick(ctx, TRUE).' in main
    assert '_landingFinish(ctx).\n    landingDiagnosticTick(ctx, TRUE).' in main
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landing_diagnostics' in closure(['landing_main'],deps)
    assert 'landing_diagnostics' not in closure(['landing_deorbit'],deps)
    clean=mask(SOURCE)
    assert not re.search(r'(?<!:)\b(?:LOCK|UNLOCK|STAGE|REBOOT|WAIT|SHUTDOWN)\b(?!:)',clean)
    assert not re.search(r'\b(?:LATLNG|landingTerrainGrade|stateSet|missionOverrideUpdate|_landingSetThrottle|_landingSetState)\s*\(',clean)
    assert '0:/cmd/' not in SOURCE and 'diagnostic_log' not in (ROOT/'lib/dependencies.ks').read_text()
    print('PASS: actual terrain/rejection data and sparse reachability rows recorded with no second scan; recorder is resident only in powered landing, ticks after guidance, exports after cleanup, and never actuates or loads archive commands')


if __name__=='__main__':
    check_buffer_and_hover()
    check_export_gates()
    check_completion_and_link_loss()
    check_candidate_capture_and_wiring()
