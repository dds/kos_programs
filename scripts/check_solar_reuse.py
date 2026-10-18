"""Execute cache/flow decisions from solar.ks; no panel physics or kOS VM."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_deorbit_geometry import Vec
from check_runtime_contracts import KList

SOURCE = (ROOT / 'lib/solar.ks').read_text()
SOURCE = SOURCE.replace('SAS OFF.', 'SET SAS TO FALSE.').replace('UNLOCK STEERING.', 'unlock().')
AERO = (ROOT/'lib/aerobrake.ks').read_text()
PHASES = (ROOT/'lib/phases.ks').read_text()
ks.SOURCES += '\n' + SOURCE+'\n'+AERO+'\n'+PHASES


class Items(KList):
    def ISTYPE(self, name): return name == 'List'


class Identity:
    def __mul__(self, axis): return axis


for index, component in enumerate('XYZ'):
    setattr(Vec, component, property(lambda self, index=index: float(self[index])))


def environment():
    primary = Vec((1, 0, 0))
    facing = NS(FOREVECTOR=primary, TOPVECTOR=Vec((0, 1, 0)), STARVECTOR=Vec((0, 0, 1)))
    module = NS(HASFIELD=lambda name: name == 'energy flow')
    panel = NS(HASMODULE=lambda name: True, GETMODULE=lambda name: module, FACING=facing)
    saved = dict(solar_axis=Items((1, 0, 0)), solar_axis_peak=10., solar_axis_distance=1e10,
                 solar_axis_panels=1, solar_axis_scaled=1)
    attempts, finishes, unlocked, reading = [], [], [], [10.]
    env = dict(SHIP=NS(STATUS='ORBITING', PARTS=Items([panel]), FACING=NS(INVERSE=Identity())),
               SUN=NS(POSITION=Vec((1e10, 0, 0))), forceSearch=False, lockSteering=False,
               overrideLaunchGuard=False, SOLAR_REUSE_RATIO=.9, LIST=lambda *xs: Items(xs),
               V=lambda *xs: Vec(xs), ROUND=round, stateGet=saved.get, stateGetNum=saved.get,
               stateSet=lambda key, value: saved.update({key: value}),
               stateRemove=lambda key: saved.pop(key, None),
               _solarSearchGuardReason=lambda _: '', _solarSunOccluded=lambda: False,
               unlock=lambda: unlocked.append(True), shipSolarFlow=lambda: reading[0],
               shipPowerFraction=lambda: .8)
    env['_solarPanelInfo'] = lambda: ks.call('_solarPanelInfo', env)
    env['_solarCacheReference'] = lambda: ks.call('_solarCacheReference', env)
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
        assert finishes[-1][2] == ('best of 6' if expect_search else 'cached axis validated')
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
    for filename, name in (('phases', 'coastHealthCheck'), ('capture', '_enterSolarCoast'), ('solar', 'solarHoldTick')):
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


def check_aerobrake_coast_entry(solar_available=True,aim_success=True,consume_budget=False):
    env,_,_,_,_,reading=environment()
    env.update(TIME=NS(SECONDS=0),WARP=4,wakeUt=40,PHASES_HAS_SOLAR=solar_available,
               SOLAR_HOLD_RATIO=.92,SOLAR_HOLD_EC=.75,AEROBRAKE_ENTRY_LEAD=900,
               KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=False)),
               _aerobrakeAtmoHeight=lambda:70000,shipHasSolarPanels=lambda:True)
    env['SHIP'].ALTITUDE=100000;reading[0]=2 # Producing power in the WRONG attitude.
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
        assert env['TIME'].SECONDS<=(budget if budget else 30)+1e-8
        assert not finishes and saved['solar_axis_peak']==10
        assert bool(unlocked)==(not expected),'non-holding caller must release failed steering'
    env,saved,attempts,finishes,_,_=environment()
    # A timeout while trying the cache cannot initiate a full search or
    # replace the proven cache with a partial, unmeasured candidate.
    env['_solarAimSettle']=lambda axis,*_: (attempts.append(axis),False)[1]
    assert ks.call('orientForSolar',env,False,True,True,12)==False
    assert len(attempts)==1 and not finishes and saved['solar_axis_peak']==10
    print('PASS: solar alignment/search respects its deadline and actual settling; failed/partial attempts preserve the proven axis and peak')


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
    for args in ((True,True),(True,False),(False,True),(True,False,True)):check_aerobrake_coast_entry(*args)
    check_settle_deadline()
    for args in ((-1,0,True),(10,5,True),(10,5,False)):check_hold_deadline(*args)
    check_hold_deferrals()
