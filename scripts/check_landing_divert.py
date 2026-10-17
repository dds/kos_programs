"""Source-driven site-diversion decisions, not KSP flight/scheduler validation."""
from types import SimpleNamespace as NS
import re

import check_landing_guidance as ks
from check_codebase import function_body
from check_runtime_contracts import run

SOURCE = (ks.ROOT / 'lib/landing_divert.ks').read_text()


def fixture():
    env = ks.environment()
    env['SHIP'].ALTITUDE=2604
    ctx = dict(HAS_TARGET=True, TARGET_LAT=0, TARGET_LNG=0, TARGET_ELEVATION=2100,
               H_SPEED=7.2, MAX_ACC=12, GRAV=1.63, TARGET_THROTTLE=.3,
               REQUESTED_LAT=0, REQUESTED_LNG=0)
    events, overrides = [], dict(SEQUENCE=['LAND_ASSIST', 'SURFACE_RETURN_SETUP'],
                                  RETURN_PE=53000)
    impact = dict(FOUND=True, DIST=79622, LAT=1, LNG=2)
    env.update(ctx=ctx, initial=True, LANDING_FLEXIBLE_SITE=1, ROUND=round,
               _landingBottomRadar=lambda: 2504,
               _landingTrajImpactInfo=lambda _: impact,
               ADDONS=NS(TR=NS(ISVERTWOTWO=True, TIMETILLIMPACT=60,
                               SETTARGET=lambda geo: events.append('target'))),
               LATLNG=lambda lat,lng: (lat,lng),
               lmDistanceToTarget=lambda lat,lng: 79622 if lat==0 else 300,
               lmApproachAcceleration=lambda *args: .277,
               _landingSetThrottle=lambda c,t: c.update(TARGET_THROTTLE=t),
               thrustCutoffOk=lambda release: events.append('cutoff') or True,
               fixture_lock=lambda statement: events.append('rebind'),
               landingTerrainGrade=lambda *args: .02,
               landingLightWindow=lambda *args: dict(OK=True, REASON='ok', SUN=15, KERBIN=20),
               geoDistance=lambda *args: 79500,
               missionOverrideUpdate=lambda changes: overrides.update(changes),
               _landingCacheTick=lambda _: events.append('refresh'))
    def survey(lat, lng, apply):
        assert ctx['TARGET_THROTTLE']==0 and not apply
        events.append(('survey', env['TERRAIN_CHECK_RADIUS']))
        return dict(LAT=lat, LNG=lng, ELEVATION=100, SHIFTED=False)
    env['_landingTerrainCheck']=survey
    return env, ctx, events, overrides


def check_diversion():
    body = function_body(SOURCE, 'landingReviewReachableSite')
    for initial in (True, False):
        env, ctx, events, overrides = fixture()
        env.update(initial=initial, _landingBottomRadar=lambda: 900)
        assert run(body, env)
        assert ctx['TARGET_LAT']==1 and ctx['TARGET_LNG']==2
        assert ctx['REQUESTED_LAT']==0 and ctx['REQUESTED_LNG']==0
        assert ctx['TARGET_ELEVATION']==100 and ctx['HOVER_TERRAIN_DONE']
        assert ctx['TARGET_THROTTLE']==0
        assert overrides['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP']
        assert overrides['RETURN_PE']==53000 and overrides['TARGET_LAT']==1
        assert events==['cutoff','rebind',('survey',100),('survey',20),'target','refresh']
        assert env['TERRAIN_CHECK_RADIUS']==100
    for precision, initial, height, speed, miss in (
            (True,True,2504,7.2,79622), (False,True,2504,400,15000),
            (False,False,2504,7.2,15000), (False,False,900,400,79622),
            (False,False,900,0,300)):
        env,ctx,events,overrides=fixture()
        env.update(LANDING_FLEXIBLE_SITE=0 if precision else 1, initial=initial,
                   _landingBottomRadar=lambda: height)
        ctx['H_SPEED']=speed
        env['_landingTrajImpactInfo']=lambda _: dict(FOUND=True,DIST=miss)
        env['lmDistanceToTarget']=lambda *args: miss
        assert run(body,env)
        assert ctx['TARGET_LAT']==0 and not events and 'TARGET_LAT' not in overrides
    print('PASS: 79.6 km miss diverts to surveyed ballistic site; return intent and original waypoint retained; precision/phantom/coast gates untouched')


def check_rejections():
    body=function_body(SOURCE,'landingReviewReachableSite')
    for failure in ('cutoff','untimed','steep','sun','radio','budget','lost-impact','past-impact','high-site'):
        env,ctx,events,overrides=fixture()
        env.update(initial=False,_landingBottomRadar=lambda: 900)
        if failure=='cutoff': env['thrustCutoffOk']=lambda _: False
        if failure=='untimed': env['ADDONS'].TR.ISVERTWOTWO=False
        if failure=='past-impact': env['ADDONS'].TR.TIMETILLIMPACT=0
        if failure=='high-site': env['SHIP'].ALTITUDE=150
        if failure=='steep': env['landingTerrainGrade']=lambda *args: .2
        if failure in ('sun','radio'):
            env['landingLightWindow']=lambda *args: dict(OK=False,REASON=failure,SUN=0,KERBIN=0)
        if failure=='budget': env['lmDistanceToTarget']=lambda *args: 79622
        if failure=='lost-impact':
            env['_landingTrajImpactInfo']=lambda _: dict(FOUND=False,DIST=79622)
        assert not run(body,env), failure
        assert ctx['TARGET_LAT']==0 and ctx['TARGET_LNG']==0, failure
        assert ctx['TARGET_THROTTLE']==0 and 'TARGET_LAT' not in overrides, failure
        assert 'refresh' not in events and 'target' not in events, failure
    print('PASS: cutoff, unknown/expired impact, altitude, slope, Sun, Kerbin and time-budget failures retain target and cannot claim a successful diversion')


def check_cpu_and_scan_order():
    main=function_body((ks.ROOT/'lib/landing_main.ks').read_text(),'landExecute')
    setup=main[main.index('LOCAL priorIpu'):main.index('IF SHIP:BODY:ATM:EXISTS')]
    boot=function_body((ks.ROOT/'lib/boot_lib.ks').read_text(),'bootPreamble')
    for initial in (150,500,2000,2500):
        saved={}
        env=ks.environment()
        env.update(CONFIG=NS(IPU=initial),stateSet=lambda k,v: saved.update({k:v}),
                   stateGetNum=lambda k,d: saved.get(k,d),
                   stateRemove=lambda k: saved.pop(k,None),bootLibLoad=lambda _: None)
        run(setup,env)
        assert env['CONFIG'].IPU==max(initial,2000)
        run(boot,env)
        assert env['CONFIG'].IPU==initial and not saved
    for marker in ('IF landingAbortFlag {','LOCAL landed IS _landingFinish(ctx).'):
        tail=main[main.index(marker):]
        assert tail.index('SET CONFIG:IPU TO priorIpu.')<tail.index('RETURN ')
    assert main.index('_landingFinalTerrainCheck(ctx)')<main.index('LOCK THROTTLE TO ctx[')
    print('PASS: landing CPU floor restored normally or on reboot; fine survey completes before the command lock can publish powered guidance')


def check_library_scope():
    # The fixture interpreter intentionally combines files. Check the split
    # files separately too: a LOCAL function cannot cross a compiled unit.
    names=('landing_main','landing_divert','landing_light','landing_light_math',
           'landing_coast','landing_brake','landing_terminal')
    files={name:(ks.ROOT/f'lib/{name}.ks').read_text() for name in names}
    for owner,source in files.items():
        for private in re.findall(r'LOCAL FUNCTION (\w+)',source):
            for caller,text in files.items():
                if caller!=owner:
                    assert not re.search(r'\b'+private+r'\s*\(',text),(owner,caller,private)
    print('PASS: shared geometry/diversion functions are exported; file-private helpers stay in their compiled unit')


if __name__=='__main__':
    check_diversion()
    check_rejections()
    check_cpu_and_scan_order()
    check_library_scope()
