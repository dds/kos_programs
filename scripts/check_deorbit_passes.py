"""Fixed-site pass forecasts against rotating conics; no KSP/TR runner."""
import math
import re
from types import SimpleNamespace as NS

import numpy as np

import check_deorbit_solver as solver
from check_codebase import ROOT, function_body
from check_runtime_contracts import run, KList


class PassList(KList):
    def REMOVE(self,index):self.pop(index)


def fixture():
    oracle=solver.kepler_oracle(mun=True)
    now=math.radians(44.593)*oracle.period/(2*math.pi)
    # Start exactly over the chosen latitude. A rotation of all axes puts
    # this synthetic meridian at any desired longitude without changing range.
    oracle.target=oracle.ground(now)
    env,count,trials=solver.environment(oracle)
    env.update(LIST=lambda *xs:PassList(xs),MOD=lambda a,b:a%b,ROUND=round,
               CONSTANT=NS(PI=math.pi),TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS=1)
    env.update(fixture_reset=lambda:setattr(count,'value',0),landingLightActive=lambda:False)
    env['TIME'].SECONDS=now
    env['SHIP'].BODY=NS(NAME='Mun',RADIUS=200000,ROTATIONPERIOD=138984)
    env['SHIP'].STATUS='ORBITING'
    env['SHIP'].PERIAPSIS=15000
    def ground(ut,*args):
        unit=oracle.ground(ut)
        return dict(VALID=True,UT=ut,ANGLE=math.degrees(math.acos(np.clip(np.dot(unit,oracle.target),-1,1))),
                    LAT=math.degrees(math.asin(np.clip(unit[2],-1,1))),
                    LNG=math.degrees(math.atan2(unit[1],unit[0])))
    env['_targetGroundAngleAt']=ground
    return env,oracle,count,trials


def check_missed_polar_pass():
    env,oracle,count,_=fixture()
    env['TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS']=0
    old=solver.planner_prefix(env,oracle.period)
    assert old is False and count.value==64
    old_cross=env['closestRejected']['CROSS']
    env,oracle,count,_=fixture()
    start=env['TIME'].SECONDS
    result=solver.planner_prefix(env,oracle.period)
    assert env['acceptedSolution'],(result,count.value,env['closestRejected'])
    assert env['geometry']['UT']>start+8*oracle.period
    assert env['solved']['CROSS']<=250 and abs(env['solved']['NORMAL'])<=10
    assert count.value<=64 and old_cross>10000
    print('PASS: an overhead polar Mun site misses the consecutive-eight-orbit search; ranked passes beyond that horizon solve the same conic footprint inside unchanged cross/normal/trial limits')


def check_forecast_bounds_and_cancel():
    env,oracle,count,_=fixture()
    earliest=env['TIME'].SECONDS+1000
    calls=[]
    original=env['_targetGroundAngleAt']
    env['_targetGroundAngleAt']=lambda ut,*args:calls.append(ut) or original(ut,*args)
    passes=env['_targetDeorbitFixedPasses'](44.593,-24.926,earliest,oracle.period,8)
    assert len(passes)==8 and count.value==0
    assert all(passes[i]['ANGLE']<=passes[i+1]['ANGLE'] for i in range(len(passes)-1))
    assert all(earliest<=item['UT']<=earliest+138984 for item in passes)
    assert len(calls)<7000
    assert all(original(item['UT']-1)['ANGLE']>=item['ANGLE']-1e-6 and
               original(item['UT']+1)['ANGLE']>=item['ANGLE']-1e-6 for item in passes)
    env,oracle,count,_=fixture()
    env['ABORT']=True
    assert not env['_targetDeorbitFixedPasses'](44.593,-24.926,1000,oracle.period,8)
    assert count.value==0
    print('PASS: bounded geometry-only ranking keeps eight local minima, orders by miss, refines their times, creates no trial nodes and honors cancellation')


def check_ranked_pass_windows():
    env,count,calls=solver.search_fixture(reachable_window=20)
    env['LIST']=lambda *xs:PassList(xs)
    env['SHIP'].STATUS='ORBITING'
    env['SHIP'].PERIAPSIS=15000
    env['TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS']=1
    env['_targetDeorbitFixedPasses']=lambda *args:PassList((dict(UT=21200,ANGLE=.1),dict(UT=31200,ANGLE=.2)))
    solver.planner_prefix(env)
    assert env['acceptedSolution'] and calls==[20] and count.value==6
    assert env['window_']['START']==20700 and env['window_']['END']==21200
    assert env['windowsTried']==1
    # Automatic sites keep their own pass context; never replace the picker.
    env,count,_=solver.search_fixture(reachable_window=2)
    env['TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS']=1
    def forbidden(*args):raise AssertionError('automatic pass was resurveyed')
    env['_targetDeorbitFixedPasses']=forbidden
    solver.planner_prefix(env,target_pass=2800)
    assert env['acceptedSolution']
    print('PASS: the ranked epoch, not its rank number, anchors each approach window; picker-provided pass context bypasses the fixed-site survey')


def check_range_seed_limits():
    for scenario in ('short-budget','invalid-probe','invalid-step','worse-step','fuel-cap','in-band','abort'):
        def response(ut,retro,normal):
            if scenario=='invalid-probe' and retro==16:return solver.impact(ut,retro,normal,0,0,False)
            if scenario=='invalid-step' and retro>16:return solver.impact(ut,retro,normal,0,0,False)
            # A locally favorable derivative followed by a worse large step.
            error=50000-1000*(retro-15)
            if scenario=='worse-step' and retro>16:error=100000
            return solver.impact(ut,retro,normal,error,2000)
        env,count,trials=solver.environment(response,budget=1 if scenario=='short-budget' else 64)
        base=solver.impact(1000,15,2,0 if scenario=='in-band' else 50000,2000)
        env['ABORT']=scenario=='abort'
        result=env['_targetDeorbitRangeSeed'](base,19,129,120,15000,10000,20000,2,
                                             20 if scenario=='fuel-cap' else 120)
        assert count.value<=12 and result['NORMAL']==2 and result['UT']==1000
        assert abs(result['ERR'])<=abs(base['ERR'])
        assert not env['_targetDeorbitSolutionAccepted'](result,10000,20000)
        if scenario in ('short-budget','in-band','abort'):assert not trials
        if scenario=='fuel-cap':assert result['RETRO']<=20
    print('PASS: range preconditioning retains valid predictions on invalid/worse probes, observes fuel/trial/abort bounds and cannot approve an excessive cross-track miss')


def check_long_coast_admission():
    # Exercise real executor coast code; stop before attitude/burn control,
    # which has its own physical cutoff and attached-node fixture.
    source=function_body((ROOT/'lib/deorbit_burn.ks').read_text(),'executeDeorbitNode')
    source=source.split('    SET SAS TO FALSE.',1)[0]
    source=re.sub(r'WAIT UNTIL (.*?)\.(?=\s*\n)',r'UNTIL \1 { WAIT 0.02. }',source,flags=re.S)
    for scenario in ('accepted','geometry-rejected','light-changed','abort','body-changed','removed','unhealthy','expired'):
        events=[]
        node=NS(TIME=100000,DELTAV=NS(MAG=10))
        ship=NS(BODY='Mun',MASS=1,AVAILABLETHRUST=10,CONTROL=NS(PILOTMAINTHROTTLE=.2))
        env=dict(nd=node,targetLat=44.593,targetLng=-24.926,TIME=NS(SECONDS=0),SHIP=ship,
                 KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),ABORT=False,HASNODE=True,ROUND=round,
                 vesselNeedsStage=lambda:False,
                 maneuverEnsureBurnAlarm=lambda *args:events.append(('alarm',args)) or 'burn-alarm',
                 vesselLandingCleanup=lambda:events.append(('cutoff',)) or True,
                 DELETEALARM=lambda alarm:events.append(('delete',alarm)),
                 solarCoastCanWarp=lambda *args:True,
                 coastHealthCheck=lambda *args:scenario!='unhealthy',
                 fixture_lock=lambda statement:events.append(('lock',statement)))
        def light(nd,lat,lng):
            events.append(('light',lat,lng))
            return scenario!='light-changed' or env['TIME'].SECONDS==0
        def solar(label,orient,health,deadline):
            events.append(('solar',deadline))
            assert orient and health and deadline==99909.5
            # Advance most of this synthetic long coast without thousands of
            # identical clock ticks. The actual final poll loop still executes.
            env['TIME'].SECONDS=deadline-20
            if scenario=='abort':env['ABORT']=True
            if scenario=='body-changed':ship.BODY='Kerbin'
            if scenario=='removed':env['HASNODE']=False
            return 1
        def warp(deadline,*args):
            events.append(('warp',deadline))
            return False  # KAC is not the script's continuation mechanism.
        def tick(ref,deadline):
            events.append(('tick',deadline))
            return ref
        def wait(dt):
            env['TIME'].SECONDS+=dt
            if scenario=='expired':node.TIME=env['TIME'].SECONDS
        def admission(nd,lat,lng):
            events.append(('geometry',lat,lng))
            return scenario!='geometry-rejected'
        env.update(landingLightNodeAllowed=light,enterSolarCoast=solar,coastAutoWarp=warp,
                   trySolarHoldTick=tick,fixture_wait=wait,beforeBurn=NS(CALL=admission))
        result=run(source,env)
        accepted=scenario in ('accepted','unhealthy')
        assert result is (None if accepted else False),(scenario,result)
        names=[event[0] for event in events]
        assert names.index('alarm')<names.index('solar')
        assert ('warp' in names)==(scenario not in ('abort','body-changed','removed','unhealthy'))
        if accepted:
            assert names.count('tick')==2 and names.count('light')==2 and 'geometry' in names
            assert env['TIME'].SECONDS==99909.5 and 'cutoff' not in names
        else:
            assert 'cutoff' in names and ('delete','burn-alarm') in events
        assert all('TO 0' in event[1] for event in events if event[0]=='lock')
        assert node.DELTAV.MAG==10 and ship.CONTROL.PILOTMAINTHROTTLE==0
    print('PASS: distant deorbit coasts install KAC before solar, keep polling, revalidate geometry/light, skip unhealthy warp and refuse ignition after abort, body change, node removal or expiry')


if __name__=='__main__':
    check_missed_polar_pass()
    check_forecast_bounds_and_cancel()
    check_ranked_pass_windows()
    check_range_seed_limits()
    check_long_coast_admission()
