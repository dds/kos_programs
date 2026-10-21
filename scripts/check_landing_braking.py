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
               BRAKE_STAGE_DV=0, DISCARD_PENDING=False, STAGE_UNTIL=0,
               BRAKE_ALIGN_BLOCKED=False,
               DIVERT_PENDING=False, DIVERT_SEARCH={},
               DIVERT_PREVIEW=dict(OK=False,AT=-9999,LOG_AT=-9999),
               DIVERT_ELEVATION=0,
               TARGET_LAT=0, TARGET_LNG=0, TARGET_ELEVATION=0,
               height=height, downrange=100000, STATE_ENTERED=0, TERRAIN_DONE=True)
    env['SHIP'] = NS(FACING=NS(FOREVECTOR=Vec((0, 0, 1))), ALTITUDE=height,
                     BOUNDS=NS(BOTTOMALTRADAR=height))
    env.update(_landingBottomRadar=lambda: ctx['height'],
               _landingTargetHeight=lambda c: c['height'],
               _landingDownrangeToTarget=lambda c: c['downrange'],
               lmDistanceToTarget=lambda *args: abs(ctx['downrange']),
               _landingSetThrottle=lambda c, x: c.update(throttle=x, TARGET_THROTTLE=x),
               _landingSetSteering=lambda c, x: c.update(steering=x),
               _landingSetState=lambda c, state, reason: c.update(STATE=state),
               _landingBoolText=str, ROUND=round, YELLOW=0, WHITE=0, GREEN=0,
               VANG=lambda a,b: math.degrees(math.acos(max(-1,min(1,float(a@b)/a.MAG/b.MAG)))),
               _landingTrajError=lambda c: dict(FOUND=False, DIST=999999,
                                               CROSS_SIGNED=0, CROSS=0),
               _landingLogBrakeComplete=lambda *args: None)
    for name in ('lmBrakeNetAcc', 'lmBrakeEnvelope', 'lmBrakeThrust',
                 'lmBrakeFullNetAcc','lmBrakeDescentTarget','lmEconomyBrakeThrust',
                 'lmNominalBrakeRange', 'lmVerticalBurnDistance', 'lmRetroSteering',
                 '_landingBurnHeight', '_landingStopEnvelope', 'lmStagedBrakeEnvelope', 'lmFullBrakeEnvelope', '_landingBrakeGateInfo',
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
    assert ctx['STATE'] == 'BRAKE_ALIGN' and ctx['throttle'] == 0
    env['SHIP'].FACING.FOREVECTOR = ctx['steering']
    call('_landingBrakeAlignTick', env, ctx)
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


def check_high_altitude_misses():
    for downrange in (-10000,5000):
        env,ctx=fixture(twr=3,horizontal=550,down=5.89,height=14000)
        ctx['downrange']=downrange
        gate=call('_landingBrakeGateInfo',env,ctx)
        assert not gate['V_NOW'] and gate['V_ETA']>env['LANDING_BRAKE_ALIGN_LEAD'],gate
        assert not gate['H_NOW'] and gate['H_ETA']>env['LANDING_BRAKE_ALIGN_LEAD'],gate
        call('_landingCoastTick',env,ctx)
        assert ctx['STATE']=='COAST' and ctx['throttle']==0,ctx
        # A missed geographic target can never suppress terrain/velocity
        # arrest once the full stopping envelope actually becomes urgent.
        ctx['height']=gate['V_GATE']-1
        call('_landingCoastTick',env,ctx)
        assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0,ctx
        env['SHIP'].FACING.FOREVECTOR = ctx['steering']
        call('_landingBrakeAlignTick',env,ctx)
        assert ctx['STATE']=='BRAKING_BURN',ctx
    for state in ('BRAKING_BURN','APPROACH','TARGET_REFINE'):
        env,ctx=fixture(twr=3,horizontal=.5 if state=='BRAKING_BURN' else 54.96,
                        down=5.89,height=13000)
        ctx.update(STATE=state,throttle=.35,downrange=-10000)
        function={'BRAKING_BURN':'_landingBrakingTick', 'APPROACH':'_landingApproachTick',
                  'TARGET_REFINE':'_landingTargetRefineTick'}[state]
        call(function,env,ctx)
        assert ctx['STATE']=='COAST' and ctx['throttle']==0,(state,ctx)
    print('PASS: 14 km missed targets cannot force early braking; 13 km approach/refinement/coasting handoffs cut thrust; urgent vertical gate survives')


def check_distant_elevated_site():
    # RO9 report: bottom=2504 m, d=79622 m, hs=7.2, vs=-0.3.
    # A high, distant site's elevation can put target-relative height inside
    # the 1 km corridor even while actual hull clearance is still 2.5 km.
    env,ctx=fixture(horizontal=7.2,down=.3,height=2504)
    paced=call('lmApproachDescentSpeed',env,30,398,79622,7.2,.277)
    assert .3 < paced < .4  # Reproduces the near-hover descent command.
    for state, function in (('APPROACH', '_landingApproachTick'),
                            ('TARGET_REFINE', '_landingTargetRefineTick')):
        env, ctx = fixture(horizontal=7.2, down=.3, height=2504)
        ctx.update(STATE=state, downrange=79622, throttle=.3)
        env['_landingTargetHeight'] = lambda _: 390
        call(function, env, ctx)
        assert ctx['STATE']=='COAST' and ctx['throttle']==0, ctx
    # A 400 m terrain shift changes only geography, not an altitude gate.
    env,ctx=fixture(twr=3,horizontal=550,down=5.89,height=12000)
    for shift in (-400,0,400):
        ctx.update(STATE='COAST',downrange=80000+shift)
        call('_landingCoastTick',env,ctx)
        assert ctx['STATE']=='COAST' and ctx['throttle']==0
    print('PASS: elevated 79.6 km target cannot admit APPROACH at 2504 m bottom; 400 m shifts do not command ignition')


def check_recorded_flare_coast():
    for height,hs,down,acc in ((2662.57,16.3306,68.6535,3.1417),
                              (2118.95,12.6557,60.6596,3.1634),
                              (1589.25,8.6367,51.5974,3.1879),
                              (1172.72,5.3252,43.0351,3.2110)):
        env,ctx=fixture(gravity=1.54,twr=acc/1.54,horizontal=hs,down=down,height=height)
        env['LANDING_ECONOMY_BRAKE']=1
        ctx.update(STATE='BRAKING_BURN',BRAKE_GRAV=65138397520.7807/200000**2)
        gate=call('_landingBrakeGateInfo',env,ctx)
        # The recorder sees height after synchronous physical cutoff; all
        # four snapshots are just below the boundary by <one coast tick.
        # Exercise the decision immediately above that same stopping gate.
        assert 0<gate['V_GATE']-height<down*.33+1
        ctx['height']=gate['V_GATE']+1
        gate=call('_landingBrakeGateInfo',env,ctx)
        assert not gate['V_NOW'] and gate['V_ETA']<env['LANDING_BRAKE_ALIGN_LEAD'],(height,gate)
        call('_landingBrakingTick',env,ctx)
        assert ctx['STATE']=='BRAKING_BURN' and ctx['TARGET_THROTTLE']==0
        ctx['height']=gate['V_GATE']-1
        env['SHIP'].FACING.FOREVECTOR=ctx['steering']
        call('_landingBrakingTick',env,ctx)
        assert ctx['STATE']=='BRAKING_BURN' and ctx['TARGET_THROTTLE']>0
        env['SHIP'].FACING.FOREVECTOR=-ctx['steering']
        call('_landingBrakingTick',env,ctx)
        assert ctx['TARGET_THROTTLE']==0
    env,ctx=fixture(horizontal=.5,down=5.89,height=13000)
    env['LANDING_ECONOMY_BRAKE']=1;ctx['STATE']='BRAKING_BURN'
    call('_landingBrakingTick',env,ctx)
    assert ctx['STATE']=='COAST' and ctx['TARGET_THROTTLE']==0
    print('PASS: four recorded flare coasts remain unpowered and aligned within the unchanged gate; ignition still requires attitude, and high-altitude arrest still returns to coast')


def simulate(gravity, twr, horizontal, down, next_twr=None, economy=False,
             start_height=None, downrange=100000, dt=.1, curvature_radius=None):
    env, ctx = fixture(gravity, twr, horizontal, down)
    env['LANDING_ECONOMY_BRAKE']=int(economy)
    env['LANDING_FLEXIBLE_SITE']=int(economy)
    if next_twr:
        ctx['PLAN_ACC'] = next_twr * gravity
    # Begin above the trigger; exercise real coast and alignment dispatch.
    ctx['height'] = call('_landingBrakeGateInfo', env, ctx)['V_GATE'] + 1000
    if start_height is not None: ctx['height']=start_height
    ctx['downrange']=downrange
    ignition, staged, spent, hover_time = None, False, 0., 0.
    minimum = ctx['height']
    for step in range(20000):
        now = step*dt
        env['TIME'].SECONDS = now
        effective_g=gravity if curvature_radius is None else max(.01,gravity-ctx['H_SPEED']**2/curvature_radius)
        ctx['GRAV']=effective_g
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
        spent += actual*ctx['MAX_ACC']*dt
        if actual>0 and abs(ctx['V_SPEED'])<5 and ctx['height']>1000:
            hover_time += dt
        assert thrust[2] >= -1e-9
        vel = Vec((ctx['H_VEL'][0],0,ctx['V_SPEED'])) + (thrust-Vec((0,0,effective_g)))*dt
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
    return dict(ignition=ignition_height,minimum=minimum,spent=spent,hover=hover_time,elapsed=now)


def hardware_fixture():
    env = environment()
    for name in ('vesselNeedsStage','vesselLandingThrust','vesselLandingNextEngineStage',
                 'vesselLandingReserveAcc', 'vesselLandingStageEvent'):
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
    env.update(SHIP=NS(ENGINES=[transfer,lander], MASS=5, THRUST=0,
                       CONTROL=NS(PILOTMAINTHROTTLE=0,MAINTHROTTLE=0),
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
             STAGE_WARNED=False,TARGET_THROTTLE=1,DISCARD_PENDING=False)
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
    stage=main.index('vesselStageForLanding(ctx, ctx["DISCARD_PENDING"])')
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
        actual=path.read_text()
        expected=original.read_text().replace('RO8','RO9')
        if path==ROOT/'craft/RO9.ks':
            # The operator explicitly enabled fuel-assisted aerobraking on RO9.
            assert actual.count('SET AEROBRAKE_AP_BURN TO 1.\n')==1
            actual=actual.replace('SET AEROBRAKE_AP_BURN TO 1.\n','')
        if path==ROOT/'missions/RO9/mun_landing_return.ks':
            # Required polar targeting, circularization and bounded lateral
            # deorbit correction have explicit RO9 settings. Their numerical
            # checks live in check_bplane_newton/arrival_budget/deorbit_solver.
            keys='BPLANE_DV_CAP|REFINE_BPLANE_DV_CAP|BPLANE_TRIM_DV_CAP|BPLANE_TRIM_TOTAL_DV_CAP|BPLANE_CAPTURE_MARGIN|SHAPE_DV_CAP|SHAPE_TOTAL_DV_CAP|TARGET_DEORBIT_NORMAL_DV_CAP|TARGET_DEORBIT_PREFERRED_CROSSTRACK_KM|DEORBIT_CROSSTRACK_AUTHORITY_KM|TARGET_DEORBIT_PASS_LOOKAHEAD_ROTATIONS|LANDING_STAGE_BRAKE_CREDIT|LANDING_ECONOMY_BRAKE|LANDING_POWERED_LEAD|LANDING_FLEXIBLE_SITE'
            actual=re.sub(r'SET ('+keys+r') TO -?\d+(?:\.\d+)?\.', '', actual)
            expected=re.sub(r'SET ('+keys+r') TO -?\d+(?:\.\d+)?\.', '', expected)
        assert clean(actual).split()==clean(expected).split(), path
    print('PASS: brake code resident before coast; stage refresh precedes guidance; RO9 preserves RO8 landing behavior with explicit aerobrake/polar-budget differences')


if __name__=='__main__':
    check_recorded_flare_coast()
    check_gates()
    check_high_altitude_misses()
    check_distant_elevated_site()
    for args in ((1.63,8,400,80),(1.63,3,300,100),(1.63,15,450,30),
                 (.491,7.45,120,60),(1.63,12,400,60,3)):
        simulate(*args)
    check_staging()
    check_integration()
