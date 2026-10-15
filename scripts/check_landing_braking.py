"""Source-driven coast/braking/staging fixtures; not KSP flight validation.

Constant gravity, point mass, instantaneous attitude after a configurable
ignition delay. No terrain mesh, engine spool, collision or kOS scheduler.
Run: python3 -B scripts/check_landing_braking.py
"""
from types import SimpleNamespace as NS
import math
import re
from check_landing_guidance import ROOT, SOURCES, call, environment, Vec
from check_launch_and_staging import body


def fixture(gravity=1.63, twr=8, horizontal=400, down=80, height=5000):
    env = environment()
    ctx = dict(HAS_TARGET=True, STATE='COAST', UP_VEC=Vec((0, 0, 1)),
               H_VEL=Vec((horizontal, 0, 0)), H_SPEED=horizontal,
               SURFACE_VEL=Vec((horizontal,0,-down)),
               V_SPEED=-down, DOWN_SPEED=down, MAX_ACC=gravity*twr,
               PLAN_ACC=gravity*twr, GRAV=gravity, BRAKE_GRAV=gravity,
               TARGET_LAT=0, TARGET_LNG=0, TARGET_ELEVATION=0,
               height=height, downrange=100000, STATE_ENTERED=0, TERRAIN_DONE=True)
    env['SHIP'] = NS(FACING=NS(FOREVECTOR=Vec((0, 0, 1))), ALTITUDE=height,
                     BOUNDS=NS(BOTTOMALTRADAR=height))
    env.update(_landingBottomRadar=lambda: ctx['height'],
               _landingTargetHeight=lambda c: c['height'],
               _landingDownrangeToTarget=lambda c: c['downrange'],
               lmDistanceToTarget=lambda *args: abs(ctx['downrange']),
               _landingSetThrottle=lambda c, x: c.update(throttle=x),
               _landingSetSteering=lambda c, x: c.update(steering=x),
               _landingSetState=lambda c, state, reason: c.update(STATE=state),
               _landingBoolText=str, ROUND=round, YELLOW=0, WHITE=0, GREEN=0,
               VANG=lambda a,b: math.degrees(math.acos(max(-1,min(1,float(a@b)/a.MAG/b.MAG)))),
               _landingTrajError=lambda c: dict(FOUND=False, DIST=999999,
                                               CROSS_SIGNED=0, CROSS=0),
               _landingLogBrakeComplete=lambda *args: None)
    for name in ('lmBrakeNetAcc', 'lmBrakeEnvelope', 'lmBrakeThrust',
                 'lmVerticalBurnDistance', 'lmRetroSteering',
                 '_landingBurnHeight', '_landingBrakeGateInfo',
                 '_landingBrakeSteeringInfo'):
        env[name] = lambda *args, name=name: call(name, env, *args)
    return env, ctx


def check_gates():
    env, ctx = fixture()
    gate = call('_landingBrakeGateInfo', env, ctx)
    old_vertical = 80**2/(2*(8*1.63-1.63))*1.03 + 15
    assert gate['V_GATE'] > old_vertical * 4  # Simultaneous 400 m/s lateral arrest matters.
    assert gate['V_ETA'] < 20
    ctx['height'] = gate['V_GATE'] - 1
    call('_landingCoastTick', env, ctx)
    assert ctx['STATE'] == 'BRAKING_BURN'
    ctx.update(height=100000, downrange=gate['H_GATE'] + 599)
    env['TERRAIN_SAFE_ALT'] = 200000
    assert call('_landingBrakeGateInfo', env, ctx)['H_NOW']
    env.update(LANDING_BRAKE_GATE_LEAD_DIST=0, LANDING_BRAKE_UNDERSHOOT_BIAS=0)
    assert not call('_landingBrakeGateInfo', env, ctx)['H_NOW']
    # Current terrain wins over a lower target; hull clearance wins over CoM.
    env['_landingTargetHeight'] = lambda c: 5000
    ctx['height'] = 300
    assert call('_landingBurnHeight', env, ctx) == 300
    env, ctx = fixture(twr=.9)
    assert call('_landingBrakeGateInfo', env, ctx)['V_NOW']
    env, ctx = fixture(twr=15, horizontal=0, down=0)
    thrust = call('lmBrakeThrust',env,ctx['H_VEL'],0,-30,ctx['UP_VEC'],ctx['MAX_ACC'],ctx['GRAV'])
    assert thrust[2] >= 0  # Coast downward; never turn the engine toward terrain.
    print(f'PASS: coupled gate {gate["V_GATE"]:.0f} m vs old {old_vertical:.0f} m; lead advances ignition; terrain wins')


def simulate(gravity, twr, horizontal, down, next_twr=None):
    env, ctx = fixture(gravity, twr, horizontal, down)
    if next_twr:
        ctx['PLAN_ACC'] = next_twr * gravity
    # Begin above the trigger; exercise real coast and alignment dispatch.
    ctx['height'] = call('_landingBrakeGateInfo', env, ctx)['V_GATE'] + 1000
    dt, ignition, staged = .1, None, False
    minimum = ctx['height']
    for step in range(20000):
        now = step*dt
        env['TIME'].SECONDS = now
        env['SHIP'].FACING.FOREVECTOR = ctx.get('steering', ctx['UP_VEC'])
        state = ctx['STATE']
        if state == 'COAST':
            call('_landingCoastTick', env, ctx)
        elif state == 'BRAKE_ALIGN':
            call('_landingBrakeAlignTick', env, ctx)
        else:
            call('_landingBrakingTick', env, ctx)
        if ctx['STATE'] == 'BRAKING_BURN' and ignition is None:
            ignition = now
            ignition_height = ctx['height']
        # Deliberately spend the entire three-second reaction reserve coasting.
        actual = ctx.get('throttle', 0) if ignition is not None and now >= ignition+3 else 0
        if next_twr and ignition is not None and now >= ignition+6:
            if not staged:
                staged = True
                ctx['MAX_ACC'] = next_twr * gravity
            # A further separation/ignition interruption during the burn.
            if now < ignition+6.5: actual = 0
        if ctx['STATE'] not in ('COAST', 'BRAKE_ALIGN', 'BRAKING_BURN'):
            break
        thrust = ctx.get('steering', ctx['UP_VEC']) * (actual * ctx['MAX_ACC'])
        assert thrust[2] >= -1e-9
        vel = Vec((ctx['H_VEL'][0],0,ctx['V_SPEED'])) + (thrust-Vec((0,0,gravity)))*dt
        ctx.update(H_VEL=Vec((vel[0],0,0)), H_SPEED=abs(vel[0]), SURFACE_VEL=vel,
                   V_SPEED=vel[2], DOWN_SPEED=max(0,-vel[2]))
        ctx['height'] += vel[2]*dt
        ctx['downrange'] -= vel[0]*dt
        minimum = min(minimum, ctx['height'])
        assert ctx['height'] > 0, (gravity,twr,horizontal,down,ctx)
    assert ignition is not None and ctx['H_SPEED'] < 1.1, ctx
    assert ctx['STATE'] == 'APPROACH', ctx
    assert minimum > 100, minimum
    assert staged == bool(next_twr)
    print(f'PASS: g={gravity} TWR={twr}->{next_twr or twr}, h/v={horizontal}/{down}: ignite {ignition_height:.0f} m, captured {minimum:.0f} m')


def hardware_fixture():
    env = environment()
    for name in ('vesselNeedsStage','vesselLandingThrust','vesselLandingNextEngineStage',
                 'vesselLandingReserveAcc'):
        env[name] = lambda *args, name=name: call(name,env,*args)
    def engine(stage, decoupled, ignition, flameout, thrust):
        eng = NS(STAGE=stage, DECOUPLEDIN=decoupled, IGNITION=ignition,
                 FLAMEOUT=flameout, AVAILABLETHRUST=thrust if ignition else 0,
                 POSSIBLETHRUST=thrust, THROTTLELOCK=False)
        def activate():
            eng.IGNITION=True
            eng.AVAILABLETHRUST=thrust
        eng.ACTIVATE=activate
        return eng
    transfer = engine(4,3,True,False,50)
    lander = engine(2,0,False,False,15)
    env.update(SHIP=NS(ENGINES=[transfer,lander], MASS=5, CONTROL=NS(PILOTMAINTHROTTLE=0),
                       PARTS=[NS(MASS=3,DECOUPLEDIN=3),NS(MASS=2,DECOUPLEDIN=-1)]),
               STAGE=NS(NUMBER=4,READY=True), ALT=NS(RADAR=3000), ROUND=round)
    events=[]
    def stage():
        env['STAGE'].NUMBER-=1
        events.append(env['STAGE'].NUMBER)
        if env['STAGE'].NUMBER==3:
            env['SHIP'].ENGINES.remove(transfer)
            env['SHIP'].MASS=2
        # Deliberately leave the engine disabled at its slot: test activation.
    env['stage_event']=stage
    ctx=dict(STAGE_UNTIL=0,STAGE_ENGINE=-1,STAGE_EVENTS=0,STAGE_ACTIVATED=False,
             STAGE_WARNED=False,TARGET_THROTTLE=1)
    return env,ctx,transfer,lander,events


def check_staging():
    env,ctx,transfer,lander,events=hardware_fixture()
    assert call('vesselLandingReserveAcc',env)==7.5
    env['SHIP'].MASS=5.5
    assert call('vesselLandingReserveAcc',env)==6
    env['SHIP'].MASS=5
    call('vesselStageForLanding',env,ctx)
    assert not events  # Burn transfer fuel first.
    transfer.FLAMEOUT=True
    for i in range(20):
        env['TIME'].SECONDS=i*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[3,2] and lander.IGNITION and ctx['STAGE_ENGINE']==-1
    # The last engine running dry must not deploy chutes or separate the pod.
    lander.FLAMEOUT=True
    for i in range(20,40):
        env['TIME'].SECONDS=i*.1
        call('vesselStageForLanding',env,ctx)
    assert events==[3,2]
    # A dead unrelated engine does not discard working propulsion.
    lander.FLAMEOUT=False
    env['SHIP'].ENGINES.append(transfer)
    assert not call('vesselNeedsStage',env)
    # Exhausted event allowance still permits activation at the selected slot.
    lander.IGNITION=False
    ctx.update(STAGE_ENGINE=2,STAGE_EVENTS=4,STAGE_ACTIVATED=False,STAGE_UNTIL=0)
    call('vesselStageForLanding',env,ctx)
    assert lander.IGNITION and events==[3,2]
    env,ctx,transfer,lander,events=hardware_fixture()
    transfer.FLAMEOUT=True
    env['STAGE'].READY=False
    call('vesselStageForLanding',env,ctx)
    assert not events
    env['LANDING_STAGE_LIMIT']=3
    assert call('vesselLandingNextEngineStage',env)==-1
    # A rejected STAGE command is bounded even if READY incorrectly stays true.
    env,ctx,transfer,lander,events=hardware_fixture()
    transfer.FLAMEOUT=True
    env['stage_event']=lambda: events.append('rejected')
    for i in range(30):
        env['TIME'].SECONDS=i*.1
        call('vesselStageForLanding',env,ctx)
    assert len(events)==4
    env['TIME'].SECONDS=10
    ctx['STAGE_UNTIL']=11
    call('_landingSetThrottle',env,ctx,1)
    assert ctx['TARGET_THROTTLE']==0
    env['TIME'].SECONDS=11
    call('_landingSetThrottle',env,ctx,1)
    assert ctx['TARGET_THROTTLE']==1
    print('PASS: transfer fuel first, separate separation/ignition, explicit activation, no staging past final engine, stage lock/limit')


def check_integration():
    main=body(SOURCES,'landExecute')
    assert main.index('_landingEnsureStateTrack("BRAKE_ALIGN")') < main.index('UNTIL landingAbortFlag')
    stage=main.index('vesselStageForLanding(ctx)')
    assert stage < main.index('_landingCacheTick(ctx)',stage) < main.index('_landingGuidanceTick(ctx)',stage)
    assert 'WAIT ' not in body(SOURCES,'vesselStageForLanding')
    # Validate profile settings and phase names against actual declarations.
    all_source='\n'.join(p.read_text() for p in (ROOT/'lib').glob('*.ks'))
    names=set(re.findall(r'GLOBAL (\w+) IS',all_source))
    for path in (ROOT/'missions/RO9').glob('*.ks'):
        text=path.read_text()
        assert not re.search('AERO9|RETRO9|DRO9',text)
        for name in re.findall(r'SET (\w+) TO',text):
            assert name in names, (path,name)
    for path in [ROOT/'craft/RO9.ks',*(ROOT/'missions/RO9').glob('*.ks')]:
        original=ROOT/str(path.relative_to(ROOT)).replace('RO9','RO8')
        clean = lambda text: re.sub(r'//[^\n]*', '', text)
        assert clean(path.read_text())==clean(original.read_text().replace('RO8','RO9')), path
    print('PASS: brake code resident before coast; stage refresh precedes guidance; RO9 literal clone matches RO8')


if __name__=='__main__':
    check_gates()
    for args in ((1.63,8,400,80),(1.63,3,300,100),(1.63,15,450,30),
                 (.491,7.45,120,60),(1.63,12,400,60,3)):
        simulate(*args)
    check_staging()
    check_integration()
