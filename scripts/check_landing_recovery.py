"""Recorded ignition/approach regressions; flat point mass, not native KSP."""
import math
from functools import lru_cache
from types import SimpleNamespace as NS

from check_landing_braking import fixture,call,Vec
from check_codebase import ROOT,function_body


def check_reported_horizontal_deadline():
    env,ctx=fixture(gravity=1.63,twr=40.66/1.63,horizontal=525.5,down=29,height=8166)
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,LANDING_STAGE_BRAKE_CREDIT=1)
    env['SHIP'].BODY=NS(RADIUS=200000)
    env['SHIP'].ALTITUDE=12279
    ctx.update(PLAN_ACC=2.45,RESERVE_ACC=2.45,BRAKE_STAGE_DV=259.3,
               BRAKE_MODEL=dict(VALID=True),downrange=18966)
    # Isolate arming policy with the nominal range measured in the log;
    # independent mass/physics integration is exercised by prediction checks.
    env['landingBrakeStackAt']=lambda *_:ctx['BRAKE_MODEL']
    env['lmNominalBrakeRange']=lambda *_:19046.
    revised=call('_landingBrakeGateInfo',env,ctx)
    shared=env['lmHorizontalBrakeGateArmed']
    env['lmHorizontalBrakeGateArmed']=lambda height,eta,valid:height<=env['TERRAIN_SAFE_ALT'] or eta<=env['LANDING_BRAKE_ALIGN_LEAD']
    old=call('_landingBrakeGateInfo',env,ctx)
    assert old['H_SUPPRESSED'] and not old['H_NOW'] and old['V_ETA']>20
    env['lmHorizontalBrakeGateArmed']=shared
    assert revised['H_NOW'] and not revised['H_SUPPRESSED'] and revised['H_ETA']==0
    assert revised['H_MODEL_VALID'] and not revised['V_NOW']
    for key in ('V_GATE','V_ETA','V_NOW'):assert revised[key]==old[key]
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['TARGET_THROTTLE']==0
    env['SHIP'].FACING.FOREVECTOR=-ctx['steering']
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['TARGET_THROTTLE']==0
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKING_BURN'
    for scenario in ('flexible','no-model','bad-range','legacy'):
        env['LANDING_FLEXIBLE_SITE']=int(scenario=='flexible')
        env['LANDING_POWERED_LEAD']=int(scenario!='legacy')
        ctx['BRAKE_MODEL']['VALID']=scenario!='no-model'
        env['lmNominalBrakeRange']=lambda *_:-1 if scenario=='bad-range' else 19046.
        gate=call('_landingBrakeGateInfo',env,ctx)
        assert gate['H_SUPPRESSED'] and not gate['H_NOW'],scenario
        assert gate['V_GATE']==revised['V_GATE'] and gate['V_NOW']==revised['V_NOW']
    planner=(ROOT/'lib/landing_deorbit_lead.ks').read_text()
    assert 'lmHorizontalBrakeGateArmed(sample["HEIGHT"],etaLo,stack["VALID"])' in planner
    print('PASS: reported525.5m/s/18.97km state admits the validated fixed-site H deadline before the~6km delay; V envelope, attitude cutoff and legacy/invalid/flexible suppression remain unchanged in flight and forecast')


@lru_cache(maxsize=None)
def simulate_approach(powered,initial_speed=.4,cross_speed=0.,height=594.,distance=4960.):
    env,ctx=fixture(gravity=1.63,twr=2.84/1.63,horizontal=abs(initial_speed),down=19.6,height=height)
    env.update(LANDING_POWERED_LEAD=int(powered),LANDING_ECONOMY_BRAKE=int(powered),
        LANDING_FLEXIBLE_SITE=0,LATLNG=lambda *_:NS(POSITION=Vec((0,0,0))),
        lmGravity=lambda:1.63,_landingFinalTerrainCheck=lambda *_:None)
    pos=Vec((distance,0,height));vel=Vec((initial_speed,cross_speed,-19.6))
    ctx.update(STATE='APPROACH',HOVER_HOLD_BOTTOM=0,HOVER_REFINED=False)
    env['_landingSetState']=lambda c,state,reason:c.update(STATE=state,STATE_ENTERED=env['TIME'].SECONDS)
    impulse=0.;elapsed=0.;min_height=height
    dt=.5
    for _ in range(3000):
        horizontal=Vec((vel[0],vel[1],0))
        ctx.update(POSITION=pos,H_VEL=horizontal,H_SPEED=horizontal.MAG,
                   V_SPEED=vel[2],DOWN_SPEED=max(0,-vel[2]),height=pos[2],
                   downrange=math.hypot(pos[0],pos[1]))
        env['TIME'].SECONDS=elapsed
        env['lmDistanceToTarget']=lambda *_:math.hypot(pos[0],pos[1])
        call('_landingHoverRefineTick' if ctx['STATE']=='HOVER_REFINE' else '_landingApproachTick',env,ctx)
        if ctx['STATE'] not in ('APPROACH','HOVER_REFINE'):
            assert ctx['STATE']=='VERTICAL_DESCENT' and ctx['downrange']<=env['LANDING_HOVER_REFINE_ACCEPT_RADIUS'],(powered,ctx['STATE'],elapsed,pos,vel,impulse)
            assert horizontal.MAG<=env['LANDING_HOVER_REFINE_ACCEPT_HSPEED']
            return elapsed,impulse,min_height
        thrust=ctx['steering']*(2.84*ctx['TARGET_THROTTLE'])
        assert thrust.MAG<=2.840001 and thrust[2]>=0
        assert thrust[2]/max(1e-9,thrust.MAG)>=math.cos(math.radians(env['MAX_TILT']))-1e-8
        accel=thrust-Vec((0,0,1.63))
        pos=pos+vel*dt+accel*dt**2/2;vel=vel+accel*dt
        impulse+=thrust.MAG*dt;elapsed+=dt;min_height=min(min_height,pos[2])
        assert pos[2]>0,('ground contact before target capture',powered,elapsed,pos,vel)
    raise AssertionError(('approach did not converge',powered,elapsed,pos,vel))


def check_legacy_approach():
    baseline=simulate_approach(False)
    assert baseline[0]>1000 and baseline[1]>1500
    print('PASS: complete legacy source replay reproduces the costly altitude-ramp recovery while retaining all integration steps; memoized for comparison')


def check_recorded_approach():
    old=simulate_approach(False)
    new=simulate_approach(True)
    assert new[0]<old[0]*.5 and new[1]<old[1]*.5,(old,new)
    assert new[2]>100
    print('PASS: recorded5km/594m recovery reaches the unchanged target/speed tolerance in %.1fs/%.1fm/s impulse versus legacy %.1fs/%.1fm/s; physical tilt/thrust/clearance retained, signed and cross-track starts converge (flat point mass)'%(new[0],new[1],old[0],old[1]))


def check_signed_approach(toward,cross):
    corrected=simulate_approach(True,toward,cross)
    assert corrected[0]<350 and corrected[2]>0,corrected
    print('PASS: actual approach source captures the same target with initial along=%.1f/cross=%.1fm/s in%.1fs, preserving thrust/tilt/ground-clearance guards'%(toward,cross,corrected[0]))


def check_transit_and_stopping_reserve():
    env,_=fixture()
    accel=.75;distance=4960
    toward=call('lmApproachTransitTime',env,distance,30,0,accel,55)
    away=call('lmApproachTransitTime',env,distance,-30,0,accel,55)
    assert abs((away-toward)-80)<1e-8
    assert call('lmApproachTransitTime',env,distance,0,8,accel,55)>call('lmApproachTransitTime',env,distance,0,0,accel,55)
    for height in (150,315,594,900):
        for down in (0,.9,10,19.6):
            plan=call('lmFixedApproachPlan',env,height,4960,0,0,down,2.84,1.63)
            assert 0<=plan['SPEED']<=env['MAX_APPROACH_SPEED'] and plan['DESCENT']>=0
            if plan['SPEED']>0:assert plan['STOP_HEIGHT']<=height+1e-6
    close=call('lmFixedApproachPlan',env,100,31,0,0,0,2.84,1.63)
    assert 0<close['SPEED']<=env['LANDING_HOVER_REFINE_MAX_SPEED']
    overspeed=call('lmFixedApproachPlan',env,315,4960,80,20,.9,2.84,1.63)
    required=call('lmBrakeEnvelope',env,math.hypot(80,20),.9,2.84,1.63,3)
    assert overspeed['STOP_HEIGHT']==required['V'] and overspeed['DESCENT']==0
    assert 'lmFixedApproachPlan' in function_body((ROOT/'lib/landing_terminal.ks').read_text(),'_landingApproachTick')
    assert 'GLOBAL FUNCTION lmFixedApproachPlan' not in (ROOT/'lib/landing_math.ks').read_text()
    print('PASS: signed closure/cross-velocity changes timing, all fast recovery requests preserve the coupled stopping-height reserve, near-ground slow settling and throttle/tilt caps remain')


def check_descending_handoff():
    for speed,down,expected in ((10,20,True),(19,20,False),(10,60,False)):
        env,ctx=fixture(gravity=1.63,twr=2.84/1.63,horizontal=speed,down=down,height=800)
        env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1)
        ctx.update(STATE='BRAKING_BURN',downrange=4960)
        # Isolate the terminal handoff without changing its V safety gate.
        env['_landingBrakeSteeringInfo']=lambda _:dict(TARGET_VS=-20,THROTTLE=.8,ALIGNED=True,
            IMPACT_ERR=4960,CROSS_ERR=0,CROSS_ABS=0,ALIGN_ERR=0,HARD=False,
            LATERAL=False,LATERAL_YAW=0,LATERAL_MISS=0)
        call('_landingBrakingTick',env,ctx)
        assert (ctx['STATE']=='APPROACH')==expected,(speed,down,ctx['STATE'])
    print('PASS: fixed-site correction can retain useful lateral motion after vertical capture; excessive horizontal speed or unsafe descent cannot take the early terminal handoff')


def check_hop_handoff():
    # Native Gamma hop: BRAKE ended at321m/15.3m/s, refinement then
    # delivered9m/s to APPROACH only106m from the target at72m altitude.
    env,ctx=fixture(gravity=.49,twr=2.69/.49,horizontal=15.3,down=15,height=247)
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,MAX_TILT=12)
    ctx.update(STATE='BRAKING_BURN',downrange=321)
    assert call('_landingApproachNeedsBrake',env,ctx)
    info=call('_landingBrakeSteeringInfo',env,ctx)
    assert info['HARD']  # Report full braking even below the old18m/s threshold.
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    call('_landingBrakingTick',env,ctx)
    assert ctx['STATE']=='BRAKING_BURN' and ctx['TARGET_THROTTLE']>0
    # Actual attitude guards still own this additional short brake.
    env['SHIP'].FACING.FOREVECTOR=-ctx['steering']
    call('_landingBrakingTick',env,ctx)
    assert ctx['TARGET_THROTTLE']==0 and ctx['STATE']=='BRAKING_BURN'
    for policy in ('flexible','legacy','no-target','high','search'):
        env,ctx=fixture(gravity=.49,twr=2.69/.49,horizontal=15.3,down=15,height=247)
        env.update(LANDING_POWERED_LEAD=int(policy!='legacy'),LANDING_ECONOMY_BRAKE=1,
                   LANDING_FLEXIBLE_SITE=int(policy=='flexible'),MAX_TILT=12)
        ctx.update(HAS_TARGET=policy!='no-target',DIVERT_PENDING=policy=='search')
        if policy=='high':ctx['height']=1100
        assert not call('_landingApproachNeedsBrake',env,ctx),policy
    print('PASS: native15.3m/s/321m hop keeps braking instead of handing excessive momentum to upright refinement; existing attitude guards and flexible/legacy/high/search paths retained')


def simulate_hop_capture(cross=0,lag=0,start='BRAKING_BURN',distance=321,height=247,speed=15.3):
    env,ctx=fixture(gravity=.49,twr=2.69/.49,horizontal=speed,down=15,height=height)
    env.update(LANDING_POWERED_LEAD=1,LANDING_ECONOMY_BRAKE=1,MAX_TILT=12,
        LATLNG=lambda *_:NS(POSITION=Vec((0,0,0)),ALTITUDEPOSITION=lambda _:Vec((0,0,0))),
        lmGravity=lambda:.49,_landingFinalTerrainCheck=lambda *_:None)
    ctx.update(STATE=start,HOVER_HOLD_BOTTOM=0,HOVER_REFINED=False,
        TARGET_REFINE_LOGGED=False,TARGET_REFINE_CLIMB_SINCE=0)
    env['_landingSetState']=lambda c,state,reason:c.update(STATE=state,STATE_ENTERED=env['TIME'].SECONDS)
    env['_landingTargetRefineSteering']=lambda c:call('_landingTargetRefineSteering',env,c)
    pos=Vec((distance,0,height));vel=Vec((-speed,cross,-15 if start=='BRAKING_BURN' else -5.9))
    facing=Vec((0,0,1));elapsed=0.;impulse=0.;min_x=distance
    ticks={'BRAKING_BURN':'_landingBrakingTick','TARGET_REFINE':'_landingTargetRefineTick',
        'APPROACH':'_landingApproachTick','HOVER_REFINE':'_landingHoverRefineTick'}
    dt=.2
    for _ in range(2000):
        horizontal=Vec((vel[0],vel[1],0))
        ctx.update(POSITION=pos,H_VEL=horizontal,H_SPEED=horizontal.MAG,V_SPEED=vel[2],
            DOWN_SPEED=max(0,-vel[2]),height=pos[2],downrange=math.hypot(pos[0],pos[1]))
        env['TIME'].SECONDS=elapsed;env['SHIP'].FACING.FOREVECTOR=facing
        env['lmDistanceToTarget']=lambda *_:math.hypot(pos[0],pos[1])
        state=ctx['STATE']
        if state not in ticks:
            assert state=='VERTICAL_DESCENT' and ctx['downrange']<=env['LANDING_HOVER_REFINE_ACCEPT_RADIUS']
            assert horizontal.MAG<=env['LANDING_HOVER_REFINE_ACCEPT_HSPEED']
            return elapsed,impulse,min_x
        call(ticks[state],env,ctx)
        direction=ctx['steering']
        if state!='BRAKING_BURN':
            assert direction[2]>=math.cos(math.radians(12))-1e-8
        elif ctx['TARGET_THROTTLE']>0:
            assert facing[2]>=0 and env['VANG'](facing,direction)<=15
        # Prescribed first-order steering lag, not a SteeringManager model.
        facing=(facing+(direction-facing)*min(1,dt/max(.01,lag))).NORMALIZED
        thrust=facing*(2.69*ctx['TARGET_THROTTLE'])
        assert 0<=ctx['TARGET_THROTTLE']<=1 and thrust.MAG<=2.690001
        acceleration=thrust-Vec((0,0,.49))
        pos=pos+vel*dt+acceleration*dt**2/2;vel=vel+acceleration*dt
        impulse+=thrust.MAG*dt;elapsed+=dt;min_x=min(min_x,pos[0])
        assert pos[2]>0,('ground contact before capture',cross,lag,elapsed,pos,vel)
    raise AssertionError(('hop capture timeout',cross,lag,pos,vel))


def check_hop_capture():
    for cross,lag in ((0,0),(0,1),(0,3),(-4,1),(4,1)):
        elapsed,impulse,min_x=simulate_hop_capture(cross,lag)
        assert elapsed<85 and impulse<65 and min_x>0,(cross,lag,elapsed,impulse,min_x)
    # An already-controlled approach must also slow before crossing the
    # target; extending BRAKE alone cannot repair the old position loop.
    for distance,speed in ((100,3),(35,1.6)):
        result=simulate_hop_capture(lag=1,start='APPROACH',distance=distance,height=72,speed=speed)
        assert result[2]>0 and result[0]<100,result
    env,_=fixture()
    for acceleration in (.083,.75):
        for distance in (5,10,30,100,1000):
            speed=call('lmApproachSpeedLimit',env,distance,acceleration)
            response=env['LANDING_APPROACH_RESPONSE_TIME']/1.25
            assert speed*response+speed**2/(2*acceleration)<=max(0,distance-5)+1e-8
            assert speed<=max(0,distance-5)/(4*response)+1e-8
    print('PASS: actual hop brake/refine/approach source captures without crossing the target in<85s/<65m/s impulse for mirrored drift and0/1/3s attitude lags; approach-only arrivals also stop before overshoot (flat point mass)')


if __name__=='__main__':
    check_reported_horizontal_deadline()
    check_legacy_approach()
    check_recorded_approach()
    check_signed_approach(-18,0)
    check_signed_approach(0,8)
    check_signed_approach(18,-5)
    check_transit_and_stopping_reserve()
    check_descending_handoff()
    check_hop_handoff()
    check_hop_capture()
