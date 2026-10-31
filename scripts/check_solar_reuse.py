"""Execute cache/flow decisions from solar.ks; no panel physics or kOS VM."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_deorbit_geometry import Vec, evaluate
from check_runtime_contracts import KList

SOURCE = (ROOT / 'lib/solar.ks').read_text()
SOURCE = SOURCE.replace('SAS OFF.', 'SET SAS TO FALSE.').replace('UNLOCK STEERING.', 'unlock().')
# KerboScript concatenates scalar values into strings; Python does not.
SOURCE = SOURCE.replace('"fixed-" + (i+1)', 'fixedLabel(i+1)')
AERO = (ROOT/'lib/aerobrake.ks').read_text()
PHASES = (ROOT/'lib/phases.ks').read_text()
ks.SOURCES += '\n' + SOURCE+'\n'+AERO+'\n'+PHASES


class Items(KList):
    def ISTYPE(self, name): return name == 'List'


class Identity:
    def __mul__(self, axis): return axis
    @property
    def INVERSE(self): return self


for index, component in enumerate('XYZ'):
    setattr(Vec, component, property(lambda self, index=index: float(self[index])))


def environment():
    primary = Vec((1, 0, 0))
    facing = NS(FOREVECTOR=primary, TOPVECTOR=Vec((0, 1, 0)), STARVECTOR=Vec((0, 0, 1)))
    module = NS(HASFIELD=lambda name: name == 'energy flow')
    panel = NS(HASMODULE=lambda name: True, GETMODULE=lambda name: module, FACING=facing)
    saved = dict(solar_axis=Items((1, 0, 0)), solar_axis_peak=10., solar_axis_distance=1e10,
                 solar_axis_panels=1, solar_axis_scaled=1,solar_axis_tolerance=1)
    attempts, finishes, unlocked, reading = [], [], [], [10.]
    env = dict(SHIP=NS(STATUS='ORBITING', PARTS=Items([panel]), FACING=NS(INVERSE=Identity()),ANGULARVEL=Vec((0,0,0))),
               SUN=NS(POSITION=Vec((1e10, 0, 0))), forceSearch=False, lockSteering=False,
               TIME=NS(SECONDS=0), WARP=0, ABORT=False,
               CONFIG=NS(IPU=150),LOG_ARCHIVE_DEFERRED=0,
               KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
               solarDiagnosticBegin=lambda *_:None,solarDiagnosticSample=lambda *_:None,
               solarDiagnosticFinish=lambda *_:None,solarDiagnosticExport=lambda *_:False,
               _solarAimDirection=lambda *_:Identity(),
               COS=lambda degrees:math.cos(math.radians(degrees)),
               SIN=lambda degrees:math.sin(math.radians(degrees)),
               fixedLabel=lambda index:'fixed-'+str(index),
               overrideLaunchGuard=False, SOLAR_REUSE_RATIO=.9, LIST=lambda *xs: Items(xs),
               V=lambda *xs: Vec(xs), CONSTANT=NS(PI=math.pi),ROUND=round, stateGet=saved.get, stateGetNum=saved.get,
               stateSet=lambda key, value: saved.update({key: value}),
               stateRemove=lambda key: saved.pop(key, None),
               _solarSearchGuardReason=lambda _: '', _solarSunOccluded=lambda: False,
               unlock=lambda: unlocked.append(True), shipSolarFlow=lambda: reading[0],
               shipPowerFraction=lambda: .8)
    env.update({name:float(value) for name,value in
                re.findall(r'GLOBAL (SOLAR_\w+) IS (\d+(?:\.\d+)?)\.',SOURCE)})
    env['_solarPanelInfo'] = lambda: ks.call('_solarPanelInfo', env)
    env['_solarCacheReference'] = lambda: ks.call('_solarCacheReference', env)
    env['_solarOrient'] = lambda *args: ks.call('_solarOrient', env, *args)
    env['_solarRefine'] = lambda axis,flow,*_:Items((axis,flow,env['SOLAR_AIM_TOLERANCE']))
    env['_solarRefinedHold'] = lambda *args:ks.call('_solarRefinedHold',env,*args)
    def aim(axis,*_):
        attempts.append(axis)
        reading[0] = max(0., float(np.dot(axis, primary))) * 10
        return True
    env['_solarAimSettle'] = aim
    env['_solarFinish'] = lambda *args: finishes.append(args)
    def rotate(angle, axis):
        angle = math.radians(angle)
        class Rotation:
            def __mul__(self, vector):
                return Vec(vector*math.cos(angle) + np.cross(axis, vector)*math.sin(angle)
                           + axis*np.dot(axis, vector)*(1-math.cos(angle)))
        return Rotation()
    env['ANGLEAXIS'] = rotate
    return env, saved, attempts, finishes, unlocked, reading


def check_cache_decisions():
    env, saved, attempts, finishes, _, _ = environment()
    ks.call('orientForSolar', env)
    assert len(attempts) == 1 and finishes[0][2] == 'cached axis validated'
    # Slightly below the peak is acceptable; below the configured floor searches.
    for flow, expect_search in ((9.1, False), (8.9, True)):
        env, saved, attempts, finishes, _, reading = environment()
        original = env['_solarAimSettle']
        def aim(axis,*args):
            original(axis)
            if len(attempts) == 1: reading[0] = flow
            return True
        env['_solarAimSettle'] = aim
        ks.call('orientForSolar', env)
        assert (len(attempts) > 1) == expect_search
        assert finishes[-1][2] == ('reference reached' if expect_search else 'cached axis validated')
    env, saved, attempts, finishes, _, reading = environment()
    saved['solar_axis'] = Items((-1, 0, 0))
    ks.call('orientForSolar', env)
    assert attempts[0][0] == -1 and finishes[-1][0][0] == 1 and len(attempts) > 1
    for occluded, flow in ((True, 0.), (False, -1.)):
        env, saved, attempts, finishes, unlocked, reading = environment()
        env['_solarSunOccluded'] = lambda: occluded
        def dark_aim(axis,*_):
            attempts.append(axis);reading[0]=flow
            return True
        env['_solarAimSettle'] = dark_aim
        ks.call('orientForSolar', env)
        assert len(attempts) == 1 and not finishes and unlocked
        assert saved['solar_axis_peak'] == 10
    env, saved, attempts, finishes, _, _ = environment()
    saved.pop('solar_axis_peak')  # Old save: measure a peak once, then future calls can validate.
    ks.call('orientForSolar', env)
    assert len(attempts) > 1 and finishes[-1][2] == 'best of 6'
    env, saved, attempts, finishes, _, _ = environment()
    ks.call('orientForSolar', env, True)
    assert len(attempts) > 1 and finishes[-1][2] == 'best of 6'
    print('PASS: saved axis tried first; near-peak reuse, low-flow search, bad-axis recovery, eclipse/unreadable retention, old-save learning and explicit forced search')


def check_reference_and_persistence():
    env, saved, _, _, _, reading = environment()
    env['SUN'].POSITION = Vec((2e10, 0, 0))
    assert env['_solarCacheReference']() == 2.5  # Inverse-square irradiance.
    saved['solar_axis_panels'] = 2
    assert env['_solarCacheReference']() < 0
    saved['solar_axis_panels'] = 1
    env['_solarPanelInfo'] = lambda: dict(COUNT=1, SCALED=0)
    saved['solar_axis_scaled'] = 0
    assert env['_solarCacheReference']() < 0  # Exposure/mixed units cannot use irradiance scaling.
    env['SUN'].POSITION = Vec((1e10, 0, 0))
    assert env['_solarCacheReference']() == 10
    ks.call('_solarFinish', env, Vec((1, 0, 0)), False, 'reuse', 11.)
    assert saved['solar_axis_peak'] == 11 and saved['solar_axis'] == [1, 0, 0]
    reading[0] = 0
    ks.call('_solarFinish', env, Vec((1, 0, 0)), False, 'eclipse')
    assert saved['solar_axis_peak'] == 11
    for filename, name in (('phases', 'coastHealthCheck'), ('coast_wait', 'enterSolarCoast'), ('solar', 'solarHoldTick')):
        code = function_body((ROOT/f'lib/{filename}.ks').read_text(), name)
        assert 'orientForSolar(TRUE' not in code
    command = (ROOT/'cmd/solarhold.ks').read_text()
    assert 'PARAMETER research IS FALSE.' in command
    orient = (ROOT/'cmd/orientForSolar.ks').read_text()
    assert orient.index('PARAMETER forceSearch') < orient.index('LOCAL FUNCTION _cmdOrientForSolar')
    print('PASS: peak saved across boots, no downward ratchet/zero overwrite, changed panels invalidate benchmark, Sun-distance scaling and automatic coast reuse')


def check_occultation():
    env, *_ = environment()
    star = NS(NAME='Sun', POSITION=Vec((1e10, 0, 0)), RADIUS=1e5, HASBODY=False)
    parent = NS(NAME='Kerbin', POSITION=Vec((-1e7, 3e6, 0)), RADIUS=600000, HASBODY=True, BODY=star)
    moon = NS(NAME='Mun', POSITION=Vec((300000, 0, 0)), RADIUS=200000, HASBODY=True, BODY=parent)
    env['SUN'], env['SHIP'].BODY = star, moon
    assert ks.call('_solarSunOccluded', env)
    moon.POSITION = Vec((-300000, 0, 0))
    assert not ks.call('_solarSunOccluded', env)
    moon.POSITION = Vec((300000, 300000, 0))
    assert not ks.call('_solarSunOccluded', env)
    parent.POSITION = Vec((1e7, 0, 0))
    assert ks.call('_solarSunOccluded', env)
    print('PASS: measured-flow cache can distinguish daylight from own-body and ancestor-body eclipses')


def check_transfer_burn_coast():
    from check_minmus_kolniya import executable
    from check_codebase import dependency_tables,closure
    maneuver=(ROOT/'lib/maneuver.ks').read_text()
    def compile_body(source):return ks.compile_nodes(ks.freeze(executable(source)))
    def execute(program,env):
        try:ks.execute(program,env)
        except ks.Returned as result:return result.value
    helper=compile_body(function_body(maneuver,'_burnCoastSolar'))
    maintenance=compile_body(function_body(PHASES,'trySolarHoldTick'))
    auto_warp=compile_body(function_body(PHASES,'coastAutoWarp'))
    owner=function_body(maneuver,'executeManeuver')
    # Run the real alarm -> attitude -> coast -> burn-relock control flow.
    # The rest of the executor's propulsion is tested in the burn fixtures.
    prefix=owner[owner.index('LOCAL aid IS'):owner.index('LOCAL apt IS')]+'}'
    prefix=re.sub(r'HUDTEXT\(.*?\)\.', '',prefix,flags=re.S)
    prefix=compile_body(prefix)
    cases=('parked','short','unavailable','failed','deadline','suborbital',
           'low-pe','next-patch','physical','raw','pilot','other-phase','no-kac')
    for case in cases:
        events=[];saved=dict(phase='MCC' if case=='other-phase' else 'XING')
        clock=NS(SECONDS=0)
        ship=NS(STATUS='ORBITING',BODY=NS(ATM=NS(EXISTS=True,HEIGHT=70000)),
                PERIAPSIS=85000,THRUST=0,ORBIT=NS(ECCENTRICITY=.001,HASNEXTPATCH=False),
                CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
        env=dict(TIME=clock,SHIP=ship,stateGet=saved.get,PHASES_HAS_SOLAR=case!='unavailable',
                 ABORT=False,resuming=False,st=400 if case=='short' else 4000,
                 bdv=1061.87,nd=NS(BURNVECTOR=Vec((1,0,0))),CRT=300,CRL=180,WARP=0,
                 COAST_AUTO_WARP=0,COAST_AUTO_WARP_MIN=60)
        if case=='suborbital':ship.STATUS='SUB_ORBITAL'
        if case=='low-pe':ship.PERIAPSIS=65000
        if case=='next-patch':ship.ORBIT.HASNEXTPATCH=True
        if case=='physical':ship.THRUST=1
        if case=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if case=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        def alarm(*args):events.append(('alarm',args[0]-60));return '' if case=='no-kac' else 'owned'
        def aim(*args):
            assert events[0][0]=='alarm' and args[:2]==(False,True)
            assert args[3]==env['st']-180
            events.append(('aim',args))
            clock.SECONDS=args[3] if case=='deadline' else clock.SECONDS+2
            return case not in ('failed','deadline')
        def hold(ref,deadline):
            assert deadline==env['st']-180
            events.append(('health',deadline));return ref
        env.update(maneuverEnsureBurnAlarm=alarm,orientForSolar=aim,
                   solarHoldTick=hold,fixture_wait=lambda dt:setattr(clock,'SECONDS',clock.SECONDS+dt),
                   fixture_lock=lambda statement:events.append(('lock',clock.SECONDS,statement)))
        env['_burnCoastSolar']=lambda deadline:execute(helper,dict(env,deadlineUt=deadline))
        env['trySolarHoldTick']=lambda *args:execute(maintenance,
                                                    dict(env,refFlow=args[0],deadlineUt=args[1]))
        env['coastAutoWarp']=lambda end,label,aid:execute(auto_warp,
                                                        dict(env,endUt=end,label=label,alarmId=aid))
        before=saved.copy();execute(prefix,env)
        aims=[row for row in events if row[0]=='aim']
        expected=case not in ('short','unavailable','physical','raw','pilot')
        assert len(aims)==int(expected),(case,events[:4])
        if aims:assert aims[0][1][2]==(case in ('parked','failed','deadline','no-kac'))
        assert saved==before and env['WARP']==0
        locks=[row for row in events if row[0]=='lock']
        assert all('nd:BURNVECTOR' in row[2] for row in locks)
        if case!='short':assert len(locks)==2 and abs(locks[-1][1]-(env['st']-180+.1))<1e-7
        else:assert len(locks)==1
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert {'solar','solar_diagnostics'}<=closure(phases['xing'],deps)
    assert 'solar' not in closure(['maneuver'],deps) # Other burn bands may shed it.
    print('PASS: real long XING wait installs its alarm before one deadline-bounded cached solar aim, preserves health ticks and returns to burn alignment180s early; short/unavailable/unsafe controls skip, failed aim/no-KAC coast still resume, and only XING adds the solar dependency')


def check_aerobrake_coast_entry(solar_available=True,aim_success=True,consume_budget=False):
    env,_,_,_,_,reading=environment()
    env.update(TIME=NS(SECONDS=0),WARP=4,wakeUt=40,PHASES_HAS_SOLAR=solar_available,
               phaseShouldYield=False,kacEnsureAlarm=lambda *args:'wake',DELETEALARM=lambda *_:None,
               SOLAR_HOLD_RATIO=.92,SOLAR_HOLD_EC=.75,AEROBRAKE_ENTRY_LEAD=900,
               KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=False)),
               _aerobrakeAtmoHeight=lambda:70000,shipHasSolarPanels=lambda:True)
    env['SHIP'].ALTITUDE=100000;reading[0]=2 # Producing power in the WRONG attitude.
    env['SHIP'].BODY='Kerbin'
    events=[]
    def tick(dt):
        env['TIME'].SECONDS+=dt
        if env['WARP']==0:env['KUNIVERSE'].TIMEWARP.ISSETTLED=True
    def aim(*args):
        assert env['WARP']==0 and env['KUNIVERSE'].TIMEWARP.ISSETTLED
        assert args==(False,True,True,40),args
        events.append('aim')
        env['TIME'].SECONDS=40 if consume_budget else env['TIME'].SECONDS+2
        if aim_success:reading[0]=10
        return aim_success
    def warp(*args):
        events.append('warp');env['WARP']=3
        return True
    env.update(orientForSolar=aim,coastAutoWarp=warp,fixture_wait=tick,
               trySolarHoldTick=lambda *args:ks.call('trySolarHoldTick',env,*args),
               solarHoldTick=lambda *args:ks.call('solarHoldTick',env,*args))
    source=function_body(AERO,'_aerobrakeSolarWait').replace('UNLOCK STEERING.','unlock().')
    source=re.sub(r'WAIT UNTIL (.*?)\.',r'UNTIL \1 { WAIT 0.05. }',source,flags=re.S)
    try:ks.run(ks.parse(source),env)
    except ks.Returned:pass
    if solar_available:
        assert events and events[0]=='aim',events
        assert ('warp' in events)==aim_success,events
    else:assert 'aim' not in events
    assert env['WARP']==0 and env['KUNIVERSE'].TIMEWARP.ISSETTLED
    if consume_budget:assert env['TIME'].SECONDS==40,'no extra coast wait after the solar deadline'
    print('PASS: aerobrake solar coast explicitly aligns before warp, even with positive initial flow; failed/unavailable solar paths are explicit')


def run_solar_body(name,env):
    source=function_body(SOURCE,name)
    source=re.sub(r'WAIT UNTIL (.*?)\.',r'UNTIL \1 { WAIT 0.05. }',source,flags=re.S)
    try:ks.run(ks.parse(source),env)
    except ks.Returned as result:return result.value


def check_settle_deadline():
    for budget,aligned,expected in ((10,True,True),(10,False,False),(1,True,False),(0,False,False)):
        env,saved,attempts,finishes,unlocked,_=environment()
        env.update(TIME=NS(SECONDS=0),aShip=Vec((1,0,0)),deadlineUt=budget,
                   keepOnFailure=False,
                   VANG=lambda *_:0 if aligned else 45,
                   _solarAim=attempts.append)
        env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=0)
        env['fixture_wait']=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt)
        assert run_solar_body('_solarAimSettle',env)==expected
        assert env['TIME'].SECONDS<=(budget if budget else env['SOLAR_AIM_TIMEOUT'])+1e-8
        assert not finishes and saved['solar_axis_peak']==10
        assert bool(unlocked)==(not expected),'non-holding caller must release failed steering'
    env,saved,attempts,finishes,_,_=environment()
    # A timeout while trying the cache cannot initiate a full search or
    # replace the proven cache with a partial, unmeasured candidate.
    env['_solarAimSettle']=lambda axis,*_: (attempts.append(axis),False)[1]
    assert ks.call('orientForSolar',env,False,True,True,12)==False
    assert len(attempts)==1 and not finishes and saved['solar_axis_peak']==10
    print('PASS: solar alignment/search respects its deadline and actual settling; failed/partial attempts preserve the proven axis and peak')


def check_long_turn_and_timeout_reason():
    class Text(str):
        def __add__(self,other):return Text(str(self)+str(other))
    for hard_deadline,align_after,expected,status in (
            (0,40,True,'settled'),(0,1000,False,'alignment-timeout'),
            (20,40,False,'search-deadline')):
        env,_,attempts,_,unlocked,_=environment()
        env.update(aShip=Vec((1,0,0)),deadlineUt=hard_deadline,keepOnFailure=False,
                   _solarAim=attempts.append)
        env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=.1)
        env['VANG']=lambda *_: 0 if env['TIME'].SECONDS>=align_after else 45
        def tick(dt):
            env['TIME'].SECONDS+=dt
            if env['TIME'].SECONDS>=align_after:env['SHIP'].ANGULARVEL.MAG=0
        logs=[]
        env.update(fixture_wait=tick,capture=logs.append,textValue=Text)
        source=function_body(SOURCE,'_solarAimSettle').replace('mLogWarn(','capture(').replace('mLog(','capture(')
        source=re.sub(r'"[^"\n]*"',lambda match:'textValue('+match[0]+')',source)
        try:ks.run(ks.parse(source),env)
        except ks.Returned as result:assert result.value==expected
        else:raise AssertionError('aim helper must return its result')
        assert any('status='+status in row for row in logs),logs
        assert all(any(key in row for row in logs) for key in ('elapsed=','err=','rate='))
        if expected:assert 40<=env['TIME'].SECONDS<43
        elif hard_deadline:assert env['TIME'].SECONDS<=hard_deadline
        else:assert abs(env['TIME'].SECONDS-env['SOLAR_AIM_TIMEOUT'])<1e-6
        assert bool(unlocked)==(not expected)
    print('PASS: a 40-second turn succeeds with the longer limit; stalled steering and hard search deadlines remain bounded and have distinct timing/error diagnostics')


def check_search_axis_route():
    rng=np.random.default_rng(71)
    for index in range(60):
        basis,_=np.linalg.qr(rng.normal(size=(3,3)))
        if index%2:basis[:,0]*=-1 # No handedness assumption.
        primary,side,other=(Vec(axis) for axis in basis.T)
        env,*_=environment()
        expression=re.search(r'LOCAL cands IS (.*?)\.',function_body(SOURCE,'_solarOrient'))[1]
        axes=evaluate(expression,env|dict(primary=primary,side=side,other=other))
        old=Items((primary,-primary,side,-side,other,-other))
        angle=lambda aa,bb:math.degrees(math.atan2(float(np.linalg.norm(np.cross(aa,bb))),float(np.dot(aa,bb))))
        assert len(axes)==6
        assert all(any(np.linalg.norm(axis-candidate)<1e-10 for candidate in axes) for axis in old)
        assert len({tuple(np.round(axis,8)) for axis in axes})==6
        assert all(abs(angle(aa,bb)-90)<1e-8 for aa,bb in zip(axes,axes[1:]))
        old_travel=sum(angle(aa,bb) for aa,bb in zip(old,old[1:]))
        new_travel=sum(angle(aa,bb) for aa,bb in zip(axes,axes[1:]))
        assert abs(old_travel-720)<1e-6 and abs(new_travel-450)<1e-6
    # Execute the reordered full search with fixed panels on every possible
    # +/- part axis; the maximum must survive the ordering change.
    for wanted in (Vec(axis)*sign for axis in np.eye(3) for sign in (-1,1)):
        env,_,attempts,finishes,_,reading=environment()
        def aim(axis,*_):
            attempts.append(axis)
            reading[0]=max(0,float(np.dot(axis,wanted)))*10
            return True
        env['_solarAimSettle']=aim
        assert ks.call('orientForSolar',env,True)
        assert finishes[-1][2]=='best of 6' and np.linalg.norm(finishes[-1][0]-wanted)<1e-10
        assert reading[0]==10
    print('PASS: 60 rotated/reflected frames retain all six panel axes with fixed 90-degree steps; full scans recover every winning axis without a tracking probe')


def check_reference_early_exit():
    for stop_at in ('fixed-1','fixed-2'):
        env,saved,attempts,finishes,_,reading=environment()
        def aim(axis,deadline,keep,label,*_):
            attempts.append(label)
            reading[0]={'cache':8,'fixed-1':3}.get(label,1)
            if label==stop_at:reading[0]=9.2
            if label=='best-hold':reading[0]=9.2
            return True
        env['_solarAimSettle']=aim
        assert ks.call('orientForSolar',env)
        assert attempts[-2:]==[stop_at,'best-hold'] and len(finishes)==1
        assert finishes[0][2:] == ('reference reached',10,5)
        assert saved['solar_axis_peak']==10
    env,saved,attempts,finishes,_,_=environment()
    saved['solar_axis_panels']=2
    assert ks.call('orientForSolar',env)
    assert finishes[-1][2]=='best of 6' and len(attempts)>6
    env,_,attempts,finishes,_,_=environment()
    assert ks.call('orientForSolar',env,True)
    assert finishes[-1][2]=='best of 6' and len(attempts)>6
    env,_,attempts,finishes,_,reading=environment()
    def tracking_aim(axis,*_):
        attempts.append(axis);reading[0]=10
        return True
    env['_solarAimSettle']=tracking_aim
    assert ks.call('orientForSolar',env,True)
    assert finishes[-1][2]=='best of 6' and len(attempts)==7
    print('PASS: automatic discovery stops at a settled near-peak candidate; invalid benchmarks and forced scans retain all six; constant tracking-panel flow needs no special inference')


def check_shared_search_budget():
    for caller_deadline in (0,70):
        env,saved,attempts,finishes,_,reading=environment()
        before=saved.copy()
        expected=caller_deadline or env['SOLAR_SEARCH_TIMEOUT']
        def slow_aim(axis,deadline,keep,label,*tolerance):
            attempts.append(label)
            assert deadline==expected
            if env['TIME'].SECONDS+50>deadline:
                env['TIME'].SECONDS=deadline
                return False
            env['TIME'].SECONDS+=50
            reading[0]=max(0,float(axis[0]))*10
            return True
        env['_solarAimSettle']=slow_aim
        assert not ks.call('orientForSolar',env,True,True,True,caller_deadline)
        assert env['TIME'].SECONDS==expected and not finishes
        assert saved==before
        assert len(attempts)>1
    print('PASS: slow multi-axis searches share one total budget, obey an earlier caller wake time, and cannot publish a partial result over the proven cache')


def check_alignment_tolerances():
    for tolerance in (None,10):
        limit=5 if tolerance is None else tolerance
        for angle,rate in ((4,0),(5,0),(5.1,0),(8,0),(10,0),(10.1,0),(0,.04)):
            env,saved,_,_,unlocked,_=environment()
            before=saved.copy()
            env.update(aShip=Vec((1,0,0)),deadlineUt=5,keepOnFailure=False,
                       VANG=lambda *_:angle,_solarAim=lambda *_:None)
            if tolerance is not None:env['tolerance']=tolerance
            env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=rate)
            env['fixture_wait']=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt)
            expected=angle<=limit and rate<.03
            assert run_solar_body('_solarAimSettle',env)==expected,(tolerance,angle,rate)
            assert env['TIME'].SECONDS<=5 and saved==before
            assert bool(unlocked)==(not expected)
    print('PASS: five-degree search and ten-degree reuse tolerances accept their boundaries; excessive drift/spin and search deadlines still reject')


def check_cached_hold_tolerance():
    for angle,flow,force,expected in ((8,9.5,False,True),(11,9.5,False,False),
                                     (8,8.9,False,False),(8,10,True,False)):
        env,saved,attempts,finishes,_,reading=environment();reading[0]=flow
        before=saved.copy()
        env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=0)
        env.update(VANG=lambda *_:angle,_solarAim=attempts.append,
                   fixture_wait=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt))
        used=[]
        def settle(axis,deadline,keep,label,*tolerance):
            used.append((label,tolerance))
            return ks.call('_solarAimSettle',env,axis,deadline,keep,label,*tolerance)
        env['_solarAimSettle']=settle
        assert ks.call('orientForSolar',env,force,True,True,12)==expected
        assert used[0]==(('fixed-1',()) if force else ('cache',(10,)))
        assert env['TIME'].SECONDS<=12
        if expected:
            assert len(attempts)==1 and finishes[0][2]=='cached axis validated'
            assert 1<=env['TIME'].SECONDS<1.2
        else:assert not finishes and saved==before
        if flow<9:assert used==[('cache',(10,)),('fixed-1',())]
    print('PASS: an eight-degree cached attitude is reused quickly only with near-peak flow; poor flow, excessive drift and forced search keep the stricter measurement path')


def check_readout_drift():
    for drift in ('angle','rate'):
        env,saved,attempts,finishes,_,_=environment()
        before=saved.copy()
        env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=0)
        env.update(VANG=lambda *_:8 if env['TIME'].SECONDS==0 or drift=='rate' else 11,
                   _solarAim=attempts.append)
        def tick(dt):
            env['TIME'].SECONDS+=dt
            if drift=='rate':env['SHIP'].ANGULARVEL.MAG=.04
        env.update(fixture_wait=tick,
                   _solarAimSettle=lambda *args:ks.call('_solarAimSettle',env,*args))
        assert not ks.call('orientForSolar',env,False,True,True,12)
        assert len(attempts)==1 and not finishes and saved==before
        assert 1.5 < env['TIME'].SECONDS <= 12
    print('PASS: excessive readout drift/spin retries within the existing deadline and cannot validate or overwrite the saved attitude')


def check_native_readout_boundary():
    # RO9 UT4665056..4665077: each turn acquires at~4.9deg, then coasts to
    # 5.15..5.25deg during the1.5s readout. The old one-shot recheck aborted
    # the scan at fixed-2, discarding the future winning fixed-5 direction.
    env,saved,attempts,finishes,_,reading=environment()
    saved.clear()
    env['SOLAR_REFINE_TIMEOUT']=0
    env['SHIP'].FACING=Identity()
    env['SHIP'].ANGULARVEL=NS(MAG=.0062)
    wanted=Vec((0,.866,.5)).NORMALIZED
    turn_start=[0.]
    def aim(axis):
        turn_start[0]=env['TIME'].SECONDS
        attempts.append(axis)
        reading[0]=10*max(0,float(np.dot(axis,wanted)))
    def error(*_):
        age=env['TIME'].SECONDS-turn_start[0]
        if age<4.8:return 94.8
        return 4.9 if age<5.2 else 5.252
    def damped_tick(dt):
        env['TIME'].SECONDS+=dt
        env['SHIP'].ANGULARVEL.MAG=.0062 if env['TIME'].SECONDS-turn_start[0]<6 else .001
    env.update(VANG=error,_solarAim=aim,
               fixture_wait=damped_tick,
               _solarAimSettle=lambda *args:ks.call('_solarAimSettle',env,*args))
    original=env['_solarFinish']
    def finish(*args):
        original(*args)
        ks.call('_solarFinish',env,*args)
    env['_solarFinish']=finish
    assert ks.call('orientForSolar',env,False,True,True)
    assert len(attempts)==7 and finishes[-1][2]=='best of 6'
    assert saved['solar_axis']==[0,1,0] and saved['solar_axis_peak']>8.6
    assert env['TIME'].SECONDS<55
    # The completed scan now supplies a proven peak for the next call:
    # validate/reuse, rather than restarting the same unsuccessful first axis.
    attempts.clear()
    assert ks.call('orientForSolar',env,False,True,True)
    assert len(attempts)==1 and finishes[-1][2]=='cached axis validated'
    print('PASS: recorded4.9->5.252deg readout jitter completes six axes, returns to the illuminated winner, persists its peak and reuses it on the next call')


def check_readout_reacquisition():
    for tolerance,drift in ((5,'angle'),(5,'rate'),(1,'angle'),(1,'rate')):
        env,_,attempts,_,_,_=environment()
        env.update(aShip=Vec((1,0,0)),tolerance=tolerance,deadlineUt=12,
                   keepOnFailure=False,_solarAim=attempts.append)
        env['SHIP'].FACING=Identity()
        env['SHIP'].ANGULARVEL=NS(MAG=0)
        samples=[]
        def error(*_):
            # Coarse drift is outside10deg; fine drift is only1.05deg and
            # must STILL fail that readout, despite being well inside10deg.
            if .4<=env['TIME'].SECONDS<.7 and drift=='angle':
                return 11 if tolerance==5 else 1.05
            return tolerance-.1
        def tick(dt):
            env['TIME'].SECONDS+=dt
            env['SHIP'].ANGULARVEL.MAG=.04 if drift=='rate' and .4<=env['TIME'].SECONDS<.7 else 0
        env.update(VANG=error,fixture_wait=tick,
                   solarDiagnosticSample=lambda label,status,*_:samples.append(status))
        assert run_solar_body('_solarAimSettle',env)
        assert 'readout-reacquire' in samples and samples[-1]=='settled'
        assert 1.7-1e-8<=env['TIME'].SECONDS<2 and len(attempts)==1
    # A tight configured coarse tolerance equal to refinement must never
    # accidentally inherit the10deg readout allowance either.
    env,_,_,_,_,_=environment()
    env.update(aShip=Vec((1,0,0)),tolerance=1,SOLAR_AIM_TOLERANCE=1,
               deadlineUt=5,_solarAim=lambda *_:None,
               VANG=lambda *_:.9 if env['TIME'].SECONDS==0 else 1.05,
               fixture_wait=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt))
    env['SHIP'].FACING=Identity();env['SHIP'].ANGULARVEL=NS(MAG=0)
    assert not run_solar_body('_solarAimSettle',env)
    assert env['TIME'].SECONDS<=5
    print('PASS: transient coarse drift/spin reacquires the same target; fine probes retain1deg precision and all retries share the original deadline')


def check_one_second_rotation_settle():
    for case in ('quiet','native-spin','damped','mid-window-spin','deadline','abort'):
        env,_,attempts,_,unlocked,_=environment()
        env.update(aShip=Vec((0,0,1)),tolerance=10,deadlineUt=10,
            keepOnFailure=False,VANG=lambda *_:7.244,_solarAim=attempts.append)
        env['SHIP'].FACING=Identity()
        env['SHIP'].ANGULARVEL=NS(MAG=.0282 if case in ('native-spin','damped','deadline') else 0)
        if case=='deadline':env['deadlineUt']=1.5
        def tick(dt):
            env['TIME'].SECONDS+=dt;now=env['TIME'].SECONDS
            if case=='damped':env['SHIP'].ANGULARVEL.MAG=.0282 if now<2 else .001
            if case=='mid-window-spin':env['SHIP'].ANGULARVEL.MAG=.0282 if .4<=now<.7 else 0
            if case=='abort' and now>=.4:env['ABORT']=True
        env['fixture_wait']=tick
        assert run_solar_body('_solarAimSettle',env)==(case in ('quiet','damped','mid-window-spin')),case
        assert len(attempts)==1
        end=env['TIME'].SECONDS
        if case=='quiet':assert 1<=end<1.2
        if case=='damped':assert 3<=end<3.2
        if case=='mid-window-spin':assert 1.7<=end<1.9
        if case=='native-spin':assert end<=9.01 and math.degrees(.0282)>1.6
        if case=='deadline':assert end<=1.5
        if case=='abort':assert end<.6
    print('PASS: native7.244deg/0.0282rad/s cannot claim settled; already-quiet attitude needs only1s, residual spin must damp first, a mid-window disturbance restarts the timer and deadlines/Abort remain bounded')


def check_soi_coast_keeps_steering():
    from check_runtime_contracts import run
    for solar,kac in ((True,True),(False,True),(True,False)):
        events=[];saved={};clock=NS(SECONDS=0)
        origin=NS(NAME='Kerbin');sun=NS(NAME='Sun')
        ship=NS(ORBIT=NS(BODY=origin,HASNEXTPATCH=True,NEXTPATCHETA=30))
        def aim(*args):
            assert events==(['alarm'] if kac else []);events.append(('aim',args))
            return True
        def tick(dt):
            clock.SECONDS+=dt
            if clock.SECONDS>=30:ship.ORBIT.BODY=sun
        source=function_body((ROOT/'lib/orbit.ks').read_text(),'waitForSOI')
        env=dict(targetBody=sun,pollInterval=5,SHIP=ship,TIME=clock,PHASES_HAS_SOLAR=solar,
            ADDONS=NS(KAC=NS(AVAILABLE=kac)),COAST_HEALTH_CHECK=0,COAST_AUTO_WARP_MIN=60,
            ensureSoiAlarm=lambda *_:events.append('alarm') or 'soi',orientForSolar=aim,
            trySolarHoldTick=lambda ref,*_:1,shipHasSolarPanels=lambda:True,
            coastHealthCheck=lambda *_:True,coastAutoWarp=lambda *_:False,
            fixture_wait=tick,DELETEALARM=lambda aid:events.append(('delete',aid)),
            stateRemove=lambda key:saved.pop(key,None),LIST=lambda *xs:Items(xs))
        run(source,env)
        if solar:assert ('aim',(False,True,False,30)) in events
        else:assert not any(isinstance(e,tuple) and e[0]=='aim' for e in events)
        assert (('delete','soi') in events)==kac and clock.SECONDS==32
    print('PASS: real Kerbin-to-Sun coast sets KAC before a deadline-bounded kept solar lock, retains clock-based SOI progression and cleans only its owned alarm')


def refinement_fixture():
    env,saved,attempts,finishes,unlocked,reading=environment()
    normal=Vec((1,.32,-.21)).NORMALIZED
    def flow(axis,label):return 10*max(0,float(np.dot(normal,axis)))
    env['fixture_flow']=flow
    env['fixture_duration']=2
    env['fixture_failed_label']=''
    def aim(axis,deadline,keep,label,tolerance=5):
        attempts.append((label,axis,deadline,tolerance,env['TIME'].SECONDS))
        if env['TIME'].SECONDS+env['fixture_duration']>deadline:
            env['TIME'].SECONDS=deadline
            return False
        env['TIME'].SECONDS+=env['fixture_duration']
        reading[0]=env['fixture_flow'](axis,label)
        return label!=env['fixture_failed_label']
    env['_solarAimSettle']=aim
    env['_solarRefine']=lambda *args:ks.call('_solarRefine',env,*args)
    return env,saved,attempts,finishes,unlocked,reading,normal


def check_refinement_measured_peak():
    env,_,attempts,_,_,_,normal=refinement_fixture()
    center=Vec((1,0,0));coarse=env['fixture_flow'](center,'coarse')
    result=env['_solarRefine'](center,coarse,300)
    assert [row[0] for row in attempts]==['refine-center','refine-1+','refine-1-',
                                          'refine-2+','refine-2-','refine-peak']
    assert np.dot(result[0],normal)>1-1e-12 and abs(result[1]-10)<1e-12
    assert result[2]==1 and result[1]>coarse*1.05
    # Two illuminated panel groups need their weighted combined normal,
    # rather than assuming the first panel's own normal is optimal.
    env,_,_,_,_,_,_=refinement_fixture()
    normals=[Vec((1,.3,0)).NORMALIZED,Vec((.6,.2,.6)).NORMALIZED]
    combined=10*normals[0]+8*normals[1]
    env['fixture_flow']=lambda axis,label:sum(weight*max(0,float(np.dot(axis,normal)))
                                             for weight,normal in zip((10,8),normals))
    result=env['_solarRefine'](center,env['fixture_flow'](center,'coarse'),300)
    assert np.dot(result[0],combined.NORMALIZED)>1-1e-12
    assert abs(result[1]-combined.MAG)<1e-12
    # A nonlinear/shaded layout can invalidate the cosine prediction.
    # Only its independent final measurement may authorize that direction.
    env,_,attempts,_,_,_,_=refinement_fixture()
    flows={'refine-center':8,'refine-1+':9,'refine-1-':5,
           'refine-2+':8,'refine-2-':8,'refine-peak':3}
    env['fixture_flow']=lambda axis,label:flows[label]
    result=env['_solarRefine'](center,8,300)
    assert attempts[-1][0]=='refine-peak' and result[1]==9
    assert np.allclose(result[0],attempts[1][1])
    # Sub-threshold jitter must not move a good center to a worse tilt.
    env,_,attempts,_,_,_,_=refinement_fixture()
    env['fixture_flow']=lambda axis,label:10 if label=='refine-center' else 10.01
    result=env['_solarRefine'](center,10,300)
    assert len(attempts)==5 and np.allclose(result[0],center) and result[1]==10
    print('PASS: four tilts recover single/multiple-panel cosine peaks; a misleading nonlinear prediction cannot beat measured flow; tiny gain noise cannot move the winner')


def check_refinement_fallback_and_budget():
    center=Vec((1,0,0))
    for disabled,deadline,abort in ((True,300,False),(False,94,False),(False,300,True)):
        env,_,attempts,_,_,_,_=refinement_fixture()
        env['ABORT']=abort
        if disabled:env['SOLAR_REFINE_TIMEOUT']=0
        result=env['_solarRefine'](center,9,deadline)
        assert not attempts and np.allclose(result[0],center) and result[1:]==[9,5]
    for failure in ('refine-center','refine-1-'):
        env,_,attempts,_,_,_,_=refinement_fixture()
        env['fixture_failed_label']=failure
        result=env['_solarRefine'](center,9,300)
        assert attempts[-1][0]==failure
        if failure=='refine-center':
            assert result[1:]==[9,5] and np.allclose(result[0],center)
        else:
            assert result[1]>=9 and result[2]==1
            measured=[(row[1],env['fixture_flow'](row[1],row[0])) for row in attempts[:-1]]
            assert any(np.allclose(result[0],axis) and abs(result[1]-flow)<1e-10
                       for axis,flow in measured)
    for deadline in (120,300):
        env,_,attempts,_,_,_,_=refinement_fixture()
        env['fixture_duration']=12
        env['_solarRefine'](center,9,deadline)
        end=min(45,deadline-90-1.5)
        assert env['TIME'].SECONDS<=end
        assert all(limit<=end and limit-start<=15 for _,_,limit,_,start in attempts)
        assert deadline-env['TIME'].SECONDS>=91.5
    print('PASS: disabled/aborted/time-tight refinement skips; stalled or partial refinement retains measured coarse/fine winners; probes share 45s and reserve the final return')


def check_refined_cache_upgrade():
    env,saved,attempts,_,_,_,normal=refinement_fixture()
    saved.pop('solar_axis_tolerance')  # Existing flight: proven coarse axis.
    saved['solar_axis_peak']=9.4
    env['_solarFinish']=lambda *args:ks.call('_solarFinish',env,*args)
    assert ks.call('orientForSolar',env,False,True,True)
    assert attempts[0][0]=='cache' and attempts[-1][0]=='best-hold'
    assert not any(row[0].startswith('fixed-') for row in attempts)
    assert saved['solar_axis_tolerance']==1 and abs(saved['solar_axis_peak']-10)<1e-9
    assert np.dot(Vec(saved['solar_axis']).NORMALIZED,normal)>.99999
    attempts.clear()
    assert ks.call('orientForSolar',env,False,True,True)
    assert [row[0] for row in attempts]==['cache'] and saved['solar_axis_tolerance']==1
    env,saved,attempts,_,_,_,_=refinement_fixture()
    saved.pop('solar_axis_peak')
    assert ks.call('orientForSolar',env,False,True,True)
    assert attempts[0][0]=='fixed-1' and not any(row[0]=='cache' for row in attempts)
    print('PASS: proven legacy cache refines without six-axis rediscovery, next call only validates; an unbenchmarked legacy axis does not duplicate the first turn')


def check_refined_hold_failure():
    for failure in ('alignment','zero','unreadable','eclipse','abort'):
        env,saved,attempts,finishes,unlocked,reading,_=refinement_fixture()
        before=saved.copy()
        env['SOLAR_REFINE_TIMEOUT']=0
        if failure=='alignment':env['fixture_failed_label']='best-hold'
        if failure in ('zero','unreadable'):
            env['fixture_flow']=lambda *_:0 if failure=='zero' else -1
        if failure=='eclipse':env['_solarSunOccluded']=lambda:True
        if failure=='abort':env['ABORT']=True
        assert not env['_solarRefinedHold'](Vec((1,0,0)),10,10,False,300,'test')
        assert saved==before and not finishes
        if failure=='abort':assert not attempts
        if failure!='alignment':assert unlocked
    print('PASS: failed return, zero/unreadable flow, eclipse or abort cannot publish a new cache; abort cannot initiate a final turn')


def check_hold_deadline(ref_flow,flow,success=True):
    env,_,_,_,_,reading=environment();reading[0]=flow
    env.update(TIME=NS(SECONDS=0),WARP=4,refFlow=ref_flow,deadlineUt=20,
               SOLAR_HOLD_RATIO=.92,SOLAR_HOLD_EC=.75,shipHasSolarPanels=lambda:True,
               shipPowerFraction=lambda:.5,KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=False)))
    events=[]
    def tick(dt):
        env['TIME'].SECONDS+=dt
        if env['WARP']==0:env['KUNIVERSE'].TIMEWARP.ISSETTLED=True
    def aim(*args):
        assert env['WARP']==0 and env['KUNIVERSE'].TIMEWARP.ISSETTLED
        assert args==(False,True,False,20)
        events.append('aim')
        if success:reading[0]=10
        return success
    def restore(rate,*_):
        events.append('restore');env['WARP']=rate
    env.update(orientForSolar=aim,fixture_wait=tick,setWarpWithKac=restore)
    result=run_solar_body('solarHoldTick',env)
    assert events==(['aim','restore'] if success else ['aim']),events
    assert result==(10 if success else ref_flow)
    env['TIME'].SECONDS=19;events.clear();reading[0]=flow
    assert run_solar_body('solarHoldTick',env)==ref_flow and not events
    print('PASS: initial zero-flow and sag re-aims settle out of warp, propagate the deadline, and restore warp/reference only after successful orientation')


def check_hold_deferrals():
    for ref,flow,charge,panels,expected in ((10,-1,.5,True,10),(-1,2,.8,True,2),
            (10,0,.5,True,10),(10,8,.8,True,10),(10,9.5,.5,True,10),
            (10,12,.5,True,12),(10,5,.5,False,10)):
        env,_,_,_,_,reading=environment();reading[0]=flow
        env.update(refFlow=ref,deadlineUt=20,TIME=NS(SECONDS=0),WARP=4,
                   SOLAR_HOLD_RATIO=.92,SOLAR_HOLD_EC=.75,
                   shipHasSolarPanels=lambda:panels,shipPowerFraction=lambda:charge,
                   _solarSunOccluded=lambda:True)
        def unexpected(*_):raise AssertionError('maintenance deferral must not initiate steering or warp')
        env.update(orientForSolar=unexpected,fixture_wait=unexpected)
        assert run_solar_body('solarHoldTick',env)==expected
        assert env['WARP']==4
    print('PASS: missing panels, unreadable flow, eclipses, healthy-battery sag, good flow and reference ratcheting retain their maintenance safeguards')


if __name__ == '__main__':
    check_cache_decisions()
    check_reference_and_persistence()
    check_occultation()
    check_transfer_burn_coast()
    for args in ((True,True),(True,False),(False,True),(True,False,True)):check_aerobrake_coast_entry(*args)
    check_settle_deadline()
    check_long_turn_and_timeout_reason()
    check_search_axis_route()
    check_reference_early_exit()
    check_shared_search_budget()
    check_alignment_tolerances()
    check_cached_hold_tolerance()
    check_readout_drift()
    check_native_readout_boundary()
    check_readout_reacquisition()
    check_one_second_rotation_settle()
    check_soi_coast_keeps_steering()
    check_refinement_measured_peak()
    check_refinement_fallback_and_budget()
    check_refined_cache_upgrade()
    check_refined_hold_failure()
    for args in ((-1,0,True),(10,0,True),(10,.1,True),(10,5,True),(10,5,False)):check_hold_deadline(*args)
    check_hold_deferrals()
