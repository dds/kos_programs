"""Source-driven fueled-stage handoff checks; no kOS VM or debris physics."""
from types import SimpleNamespace as NS
import math

from check_landing_braking import hardware_fixture, call, fixture as brake_fixture, Vec
from check_landing_guidance import SOURCES,parse,run,Returned
from check_launch_and_staging import body
from check_codebase import ROOT, mask, command_entrypoint_errors


def fixture():
    env,ctx,transfer,lander,events = hardware_fixture()
    mass = 55/42.7443409590144
    wet_lander = 2/2.74023930174613
    transfer.STAGE,transfer.DECOUPLEDIN,transfer.AVAILABLETHRUST = 2,1,55
    lander.STAGE,lander.DECOUPLEDIN,lander.POSSIBLETHRUST = 1,-1,2
    world = NS(NAME='Minmus',ATM=NS(EXISTS=False))
    env['SHIP'].BODY = world
    env['SHIP'].ORBIT = NS(ECCENTRICITY=.3)
    env['SHIP'].PERIAPSIS = -8179
    env['SHIP'].MASS = mass
    env['SHIP'].PARTS = [NS(MASS=mass-wet_lander,DECOUPLEDIN=1),NS(MASS=wet_lander,DECOUPLEDIN=-1)]
    env['SHIP'].DELTAV = NS(VACUUM=1817.1)
    env['SHIP'].THRUST = 55
    env['STAGE'].NUMBER = 2
    env['STAGE'].DELTAV = NS(VACUUM=364.9)
    ctx.update(STATE='BRAKING_BURN',H_SPEED=79,DOWN_SPEED=30,V_SPEED=-30,
               BRAKE_GRAV=.4905,height=1800,DISCARD_TRIED=False,
               DISCARD_PENDING=False,DISCARD_SINCE=0)
    env.update(LANDING_STAGE_DISCARD_HSPEED=80,LANDING_STAGE_DISCARD_RESERVE_DV=700,
               LANDING_ECONOMY_BRAKE=1,LANDING_FLEXIBLE_SITE=1,HASNODE=False,
               ETA=NS(PERIAPSIS=200), CORE=NS(PART=NS(DECOUPLEDIN=-1)),
               ORBITAT=lambda *args:NS(BODY=world),lmGroundGeoAt=lambda ut:NS(TERRAINHEIGHT=3000),
               _landingBurnHeight=lambda c:c['height'])
    for name in ('lmBrakeNetAcc','lmBrakeEnvelope','landingStageDisposalInfo',
                 '_landingSetThrottle'):
        env[name] = lambda *args,name=name:call(name,env,*args)
    def stage():
        assert env['SHIP'].THRUST == 0
        assert ctx['TARGET_THROTTLE'] == 0
        assert env['SHIP'].CONTROL.MAINTHROTTLE == env['SHIP'].CONTROL.PILOTMAINTHROTTLE == 0
        env['STAGE'].NUMBER -= 1
        events.append(env['STAGE'].NUMBER)
        env['SHIP'].ENGINES.remove(transfer)
        env['SHIP'].MASS = wet_lander
    env['stage_event'] = stage
    return env,ctx,transfer,lander,events


def check_handoff():
    env,ctx,transfer,lander,events = fixture()
    info = call('landingStageDisposalInfo',env,ctx)
    assert info['OK'] and 1452 < info['DV'] < 1453 and info['REQUIRED_DV'] < 900,info
    assert 0 < info['GATE'] < ctx['height'],info
    call('landingStageDisposalTick',env,ctx)
    assert ctx['DISCARD_PENDING'] and not events and ctx['TARGET_THROTTLE'] == 0
    # Live guidance cannot overwrite the pending cutoff, and the fuel-first
    # recovery driver cannot stage/reset the pending request behind its back.
    call('_landingSetThrottle',env,ctx,1)
    assert ctx['TARGET_THROTTLE'] == 0
    call('vesselStageForLanding',env,ctx,ctx['DISCARD_PENDING'])
    assert ctx['DISCARD_PENDING'] and not events
    env['SHIP'].THRUST = 0
    env['TIME'].SECONDS = .02
    call('landingStageDisposalTick',env,ctx)
    assert not events
    env['TIME'].SECONDS = .1
    call('landingStageDisposalTick',env,ctx)
    assert events == [1] and not ctx['DISCARD_PENDING']
    assert env['STAGE'].DELTAV.VACUUM > 300  # Deliberately fueled, not empty.
    call('_landingSetThrottle',env,ctx,1)
    assert ctx['TARGET_THROTTLE'] == 0  # Existing separation/ignition settle.
    for tick in range(2,15):
        env['TIME'].SECONDS = tick*.1
        call('vesselStageForLanding',env,ctx)
        call('landingStageDisposalTick',env,ctx)
    assert lander.IGNITION and events == [1]
    lander.FLAMEOUT = True
    for tick in range(15,30):
        env['TIME'].SECONDS = tick*.1
        call('vesselStageForLanding',env,ctx)
    assert events == [1]  # Never advance into return/payload/chute slots.
    print('PASS: recorded RO9 stack has 1452m/s lander budget; fueled transfer separation waits for physical zero, protects every throttle command and settles/activates only the selected lander')


def check_rejections():
    mutations = [
        ('stack',lambda e,c,t,l:setattr(t,'DECOUPLEDIN',0)),
        ('stack',lambda e,c,t,l:setattr(e['STAGE'],'NUMBER',3)),
        ('stack',lambda e,c,t,l:setattr(e['CORE'].PART,'DECOUPLEDIN',1)),
        ('stack',lambda e,c,t,l:e.update(LANDING_STAGE_LIMIT=2)),
        ('stack',lambda e,c,t,l:e['SHIP'].ENGINES.append(NS(IGNITION=False,FLAMEOUT=False,
            POSSIBLETHRUST=2,DECOUPLEDIN=-1,STAGE=0,THROTTLELOCK=False))),
        ('lander-acceleration',lambda e,c,t,l:e.update(vesselLandingReserveAcc=lambda:.4)),
        ('lander-acceleration',lambda e,c,t,l:e.update(vesselLandingReserveAcc=lambda:float('nan'))),
        ('lander-clearance',lambda e,c,t,l:c.update(height=100)),
        ('lander-clearance',lambda e,c,t,l:e.update(LANDING_STAGE_SETTLE=10,LANDING_BRAKE_REACTION_TIME=0)),
        ('disposal-speed',lambda e,c,t,l:c.update(H_SPEED=20)),
        ('lander-fuel',lambda e,c,t,l:setattr(e['SHIP'].DELTAV,'VACUUM',1000)),
        ('lander-fuel',lambda e,c,t,l:setattr(e['STAGE'].DELTAV,'VACUUM',float('nan'))),
        ('ballistic-disposal',lambda e,c,t,l:e.update(HASNODE=True)),
        ('ballistic-disposal',lambda e,c,t,l:setattr(e['SHIP'].BODY.ATM,'EXISTS',True)),
        ('ballistic-disposal',lambda e,c,t,l:setattr(e['SHIP'].ORBIT,'ECCENTRICITY',1.1)),
        ('ballistic-disposal',lambda e,c,t,l:setattr(e['SHIP'],'PERIAPSIS',4000)),
        ('ballistic-disposal',lambda e,c,t,l:c.update(V_SPEED=0)),
        ('ballistic-disposal',lambda e,c,t,l:e.update(ORBITAT=lambda *args:NS(BODY=NS(NAME='Kerbin')))),
    ]
    for reason,mutate in mutations:
        env,ctx,transfer,lander,events = fixture()
        mutate(env,ctx,transfer,lander)
        info = call('landingStageDisposalInfo',env,ctx)
        assert not info['OK'] and info['REASON'] == reason,(reason,info)
        call('landingStageDisposalTick',env,ctx)
        assert not events and not ctx['DISCARD_PENDING']
    # Default, precision, coast, high-speed and already-slow guidance never
    # request elective staging or interrupt the working engine.
    for mutate in (lambda e,c:e.update(LANDING_STAGE_DISCARD_HSPEED=0),
                   lambda e,c:e.update(LANDING_ECONOMY_BRAKE=0),
                   lambda e,c:e.update(LANDING_FLEXIBLE_SITE=0),
                   lambda e,c:c.update(STATE='COAST'),
                   lambda e,c:c.update(H_SPEED=100),lambda e,c:c.update(H_SPEED=20)):
        env,ctx,transfer,lander,events = fixture()
        mutate(env,ctx)
        call('landingStageDisposalTick',env,ctx)
        assert not ctx['DISCARD_TRIED'] and ctx['TARGET_THROTTLE'] == 1 and not events
    print('PASS: fuel, weaker-stage clearance, engine/core retention, stage limits, nodes, atmosphere, SOI, bound-orbit and measured-terrain contact gates reject unsafe elective separation; default/precision/coast behavior unchanged')


def check_failed_cutoff():
    for fault in ('thrust','nan-thrust','stage-ready','terrain-change','abort','late-ready','speed-captured'):
        env,ctx,transfer,lander,events = fixture()
        call('landingStageDisposalTick',env,ctx)
        if fault == 'nan-thrust': env['SHIP'].THRUST = float('nan')
        if fault == 'stage-ready':
            env['SHIP'].THRUST = 0
            env['STAGE'].READY = False
        if fault == 'terrain-change': ctx['height'] = 100
        if fault == 'abort': env['ABORT'] = True
        if fault == 'late-ready': env['SHIP'].THRUST = 0
        if fault == 'speed-captured':
            env['SHIP'].THRUST = 0
            ctx['H_SPEED'] = 20
        for tick in range(1,25):
            env['TIME'].SECONDS = tick*.1 + (1 if fault=='late-ready' else 0)
            call('landingStageDisposalTick',env,ctx)
            call('vesselStageForLanding',env,ctx,ctx['DISCARD_PENDING'])
        assert not events and not ctx['DISCARD_PENDING'] and transfer in env['SHIP'].ENGINES
        if fault == 'abort':
            call('_landingSetThrottle',env,ctx,1)
            assert ctx['TARGET_THROTTLE'] == 0
            env['ABORT'] = False
        call('_landingSetThrottle',env,ctx,1)
        assert ctx['TARGET_THROTTLE'] == 1
    # The common event cannot detach a thrusting engine even if called directly.
    env,ctx,transfer,lander,events = fixture()
    assert not call('vesselLandingStageEvent',env,ctx,1) and not events
    env['ABORT'],env['SHIP'].THRUST = True,0
    assert not call('vesselLandingStageEvent',env,ctx,1) and not events
    transfer.FLAMEOUT = True
    call('vesselStageForLanding',env,ctx)
    assert not events and not lander.IGNITION
    # Landing previously never read ABORT. Its owner now exits via the
    # existing cleanup path, without loading another guidance track first.
    env.update(ctx=ctx,landingAbortFlag=False,
               _landingEnsureStateTrack=lambda *args: (_ for _ in ()).throw(AssertionError('abort must precede track loading')))
    try: run(parse(body(SOURCES,'_landingGuidanceTick')),env)
    except Returned: pass
    assert env['landingAbortFlag'] and ctx['TARGET_THROTTLE'] == 0
    assert 'WAIT ' not in body(SOURCES,'landingStageDisposalTick')
    main = body(SOURCES,'landExecute')
    step = main.index('landingStageDisposalTick(ctx)')
    assert step < main.index('vesselStageForLanding(ctx, ctx["DISCARD_PENDING"])',step) < main.index('_landingCacheTick(ctx)',step) < main.index('_landingGuidanceTick(ctx)',step)
    print('PASS: persistent/invalid thrust, unavailable staging and falling clearance cancel elective disposal and retain propulsion; cutoff is tick-driven, with mass/thrust refresh before guidance')


def check_override_command():
    import re
    source = (ROOT/'cmd/landingdisposal.ks').read_text()
    assert not command_entrypoint_errors(source)
    clean = mask(source)
    assert not re.search(r'\b(?:STAGE|ADD|REMOVE|LOCK|UNLOCK|REBOOT)\b',clean)
    assert not re.search(r'\b(?:stateSet|stateRemove|missionOverrideClear|executeManeuver)\s*\(',clean)
    keys = re.findall(r'"(LANDING_STAGE_DISCARD_\w+)"',source)
    assert keys == ['LANDING_STAGE_DISCARD_HSPEED','LANDING_STAGE_DISCARD_RESERVE_DV']
    assert 'missionOverrideUpdate(' in source
    assert 'landing_disposal' not in body((ROOT/'lib/dependencies.ks').read_text(),'dependencyLibs').split('"landing_main"',1)[0]
    print('PASS: inflight configuration command changes only the two disposal overrides, preserves node/phase/other overrides, and never stages or executes a burn')


def check_recorded_brake_model():
    # The companion Kepler fixture derives this entry on the recorded node
    # over a flat surface at the target's logged 3602.9m elevation. Here the
    # production vector controller flies a point mass with fuel/mass changes,
    # instantaneous attitude and deliberately long 3s ignition + 3s handoff
    # delays. No terrain mesh, scheduler, debris or terminal landing proof.
    results = []
    for discard in (False,True):
        reserve,gravity = 2.74023930174613,.4905
        env,ctx = brake_fixture(gravity=gravity,horizontal=151.08294,down=27.66997,height=1468.2684)
        env['LANDING_ECONOMY_BRAKE'] = 1
        ctx.update(PLAN_ACC=reserve,STATE='BRAKING_BURN')
        mass = 55/42.7443409590144*math.exp(-14.8535/(295*9.80665))
        lander_wet = 2/reserve
        transfer_dry = 55/42.7443409590144*math.exp(-364.9/(295*9.80665))
        lander_dry = lander_wet*math.exp(-(1817.1-364.9)/(315*9.80665))
        staged,pending = False,None
        elapsed,spent,distance = 0.,0.,7386.26
        handoff_height = None
        def steer(context,vector):
            context['steering'] = vector
            env['SHIP'].FACING.FOREVECTOR = vector
        env['_landingSetSteering'] = steer
        while elapsed < 200 and ctx['H_SPEED'] > 18:
            radius = 60000+3602.9+ctx['height']
            effective_g = max(.01,1.7658e9/radius**2-ctx['H_SPEED']**2/radius)
            ctx.update(GRAV=effective_g,MAX_ACC=(2 if staged else 55)/mass)
            env['TIME'].SECONDS = elapsed
            info = call('_landingBrakeSteeringInfo',env,ctx)
            throttle = info['THROTTLE'] if elapsed >= 3 else 0
            if discard and not staged and pending is None and ctx['H_SPEED'] <= 80:
                pending = elapsed
                handoff_height = ctx['height']
                gate = call('lmBrakeEnvelope',env,ctx['H_SPEED'],ctx['DOWN_SPEED'],reserve,gravity,3)
                assert ctx['height'] > gate['V']+500
            if pending is not None and not staged:
                throttle = 0
                if elapsed >= pending+3: staged,mass = True,lander_wet
            thrust = ctx['steering']*(throttle*ctx['MAX_ACC'])
            spent += throttle*ctx['MAX_ACC']*.25
            mass -= throttle*(2 if staged else 55)/((315 if staged else 295)*9.80665)*.25
            assert mass > (lander_dry if staged else transfer_dry)
            velocity = Vec((ctx['H_SPEED'],0,ctx['V_SPEED']))+(thrust-Vec((0,0,effective_g)))*.25
            distance += (ctx['H_SPEED']+velocity[0])/2*.25
            ctx['height'] += (ctx['V_SPEED']+velocity[2])/2*.25
            ctx.update(H_SPEED=float(velocity[0]),H_VEL=Vec((velocity[0],0,0)),
                       V_SPEED=float(velocity[2]),DOWN_SPEED=max(0,-float(velocity[2])))
            assert ctx['height'] > 700 and ctx['V_SPEED'] < -20
            elapsed += .25
        assert ctx['H_SPEED'] <= 18 and spent < 140 and staged == discard
        assert 8000 < distance < 9500
        results.append((staged,round(ctx['height']),round(distance),round(spent)))
        if discard: assert handoff_height > 1300
    print(f'PASS: recorded hardware model keeps descending through 80m/s handoff and 3s gap, captures main brake above 700m; (discard,height,aimpoint miss,impulse)={results}; not a touchdown/debris guarantee')


if __name__ == '__main__':
    check_handoff()
    check_rejections()
    check_failed_cutoff()
    check_override_command()
    check_recorded_brake_model()
