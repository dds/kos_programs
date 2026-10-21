"""Serial-stage braking regressions; no KSP, terrain or attitude runner."""
import math
import random
from types import SimpleNamespace as NS

from check_landing_braking import fixture, call, Vec
from check_runtime_contracts import KList
from check_codebase import ROOT, closure, dependency_tables
from check_surface_return import read_settings


class Mixture(dict):
    @property
    def LENGTH(self):return len(self)
    @property
    def VALUES(self):return KList(self.values())


def hardware():
    env,ctx=fixture()
    mass,isp,budget=1.287,320,313
    units=mass*(1-math.exp(-budget/(isp*9.80665)))/.005
    fuels=[NS(NAME=name,RATIO=ratio,DENSITY=.005)
           for name,ratio in (('LiquidFuel',.45),('Oxidizer',.55))]
    held=[NS(NAME=fuel.NAME,AMOUNT=units*fuel.RATIO,ENABLED=True) for fuel in fuels]
    active=NS(STAGE=3,DECOUPLEDIN=1,IGNITION=True,FLAMEOUT=False,AVAILABLETHRUST=55,
              POSSIBLETHRUST=55,THROTTLELOCK=False,MULTIMODE=False,VISP=isp,
              CONSUMEDRESOURCES=Mixture((fuel.NAME,fuel) for fuel in fuels))
    lander=NS(STAGE=1,DECOUPLEDIN=-1,IGNITION=False,FLAMEOUT=False,AVAILABLETHRUST=0,
              POSSIBLETHRUST=2.5,THROTTLELOCK=False)
    ship=NS(MASS=mass,BODY=NS(ATM=NS(EXISTS=False)),ENGINES=[active,lander],
            PARTS=[NS(DECOUPLEDIN=1,RESOURCES=held),
                   NS(DECOUPLEDIN=-1,RESOURCES=[NS(NAME='LiquidFuel',AMOUNT=1000,ENABLED=True)])])
    env.update(SHIP=ship,STAGE=NS(NUMBER=2,DELTAV=NS(VACUUM=budget)),
               CORE=NS(PART=NS(DECOUPLEDIN=-1)),LN=math.log)
    env['vesselLandingNextEngineStage']=lambda:call('vesselLandingNextEngineStage',env)
    return env,ctx,active,lander,held


def check_fuel_credit():
    env,_,active,lander,held=hardware()
    assert abs(call('vesselLandingBrakeStageDv',env)-313)<1e-9
    env['STAGE'].DELTAV.VACUUM=10000
    assert abs(call('vesselLandingBrakeStageDv',env)-313)<1e-9
    held[1].AMOUNT/=2
    expected=320*9.80665*math.log(1/(1-(1-math.exp(-313/(320*9.80665)))/2))
    assert abs(call('vesselLandingBrakeStageDv',env)-expected)<1e-9
    held[0].AMOUNT=0
    assert call('vesselLandingBrakeStageDv',env)==0  # Retained lander tank cannot subsidize credit.
    for kind in ('zero-stock','disabled','no-mixture','massless','atmosphere','parallel','extra-slot','core-dropped','multimode','solid','final-engine'):
        env,_,active,lander,held=hardware()
        if kind=='zero-stock':env['STAGE'].DELTAV.VACUUM=0
        if kind=='disabled':held[0].ENABLED=False
        if kind=='no-mixture':active.CONSUMEDRESOURCES.clear()
        if kind=='massless':active.CONSUMEDRESOURCES['EC']=NS(RATIO=.001,DENSITY=0)
        if kind=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if kind=='parallel':env['SHIP'].ENGINES.append(active)
        if kind=='extra-slot':env['STAGE'].NUMBER=3
        if kind=='core-dropped':env['CORE'].PART.DECOUPLEDIN=1
        if kind=='multimode':active.MULTIMODE=True
        if kind=='solid':active.THROTTLELOCK=True
        if kind=='final-engine':lander.POSSIBLETHRUST=0
        assert call('vesselLandingBrakeStageDv',env)==0,kind
    print('PASS: current-stage credit is capped by limiting enabled propellant, rocket equation and stock dV; retained fuel, empty/unsupported stacks and atmospheric vacuum estimates cannot supply credit')


def check_live_stage_cache():
    profile=read_settings((ROOT/'missions/RO9/mun_landing_return.ks').read_text(),{})
    assert profile['LANDING_STAGE_BRAKE_CREDIT']==1 and profile['LANDING_ECONOMY_BRAKE']==1
    assert profile['TARGET_LOCK']==1 and profile['LANDING_AUTO_TARGET']==0
    assert profile['LANDING_FLEXIBLE_SITE']==0
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'landing_stage_brake' in closure(['landing_main'],deps)
    assert 'landing_stage_brake' in closure(['deorbit_targeting'],deps)
    assert 'landing_main' not in closure(['deorbit_targeting'],deps)
    assert 'landing_brake' not in closure(['deorbit_targeting'],deps)
    env,ctx,active,lander,held=hardware()
    ship=env['SHIP']
    ship.VELOCITY=NS(SURFACE=Vec((504.9,0,-3.8)))
    ship.UP=NS(VECTOR=Vec((0,0,1)))
    ship.POSITION=Vec((0,0,210000))
    ship.BODY.MU=6.5138398e10;ship.BODY.RADIUS=200000
    ship.VERTICALSPEED=-3.8
    ctx.update(RESERVE_STAGE=-999,RESERVE_ACC=0,DISCARD_PENDING=False)
    env.update(LANDING_STAGE_BRAKE_CREDIT=1,VDOT=lambda a,b:float(a@b),
               vesselLandingThrust=lambda:55,
               vesselLandingReserveAcc=lambda:2.72,lmGravity=lambda:.25,
               vesselLandingBrakeStageDv=lambda:call('vesselLandingBrakeStageDv',env))
    call('_landingCacheTick',env,ctx)
    assert abs(ctx['BRAKE_STAGE_DV']-313)<1e-9 and ctx['PLAN_ACC']==2.72
    held[0].AMOUNT=0
    call('_landingCacheTick',env,ctx)
    assert ctx['BRAKE_STAGE_DV']==0 and ctx['PLAN_ACC']==2.72
    held[0].AMOUNT=100;ctx['DISCARD_PENDING']=True
    call('_landingCacheTick',env,ctx)
    assert ctx['BRAKE_STAGE_DV']==0
    env['LANDING_STAGE_BRAKE_CREDIT']=0
    call('_landingCacheTick',env,ctx)
    assert ctx['BRAKE_STAGE_DV']==0
    print('PASS: the real guidance cache refreshes the bounded fuel credit, observes exhaustion/pending disposal/opt-out and preserves the weaker-stage PLAN_ACC')


def check_reported_gate():
    env,ctx=fixture(gravity=1.6284599,twr=44.68/1.6284599,horizontal=504.9,down=3.8,height=9149)
    ctx.update(PLAN_ACC=2.72,BRAKE_STAGE_DV=313)
    old=call('_landingBrakeGateInfo',env,ctx)
    assert old['H_NOW'] and not old['V_NOW'] and old['H_GATE']>150000 and old['V_ETA']<20
    env['LANDING_STAGE_BRAKE_CREDIT']=1
    revised=call('_landingBrakeGateInfo',env,ctx)
    assert not revised['H_NOW'] and not revised['V_NOW'] and revised['V_ETA']>20
    assert 47000<revised['H_GATE']<49000
    for shift in (-640,0,640):
        ctx.update(STATE='COAST',downrange=100000+shift)
        call('_landingCoastTick',env,ctx)
        assert ctx['STATE']=='COAST' and ctx['throttle']==0
    ctx['height']=revised['V_GATE']-1
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKE_ALIGN' and ctx['throttle']==0
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    call('_landingBrakeAlignTick',env,ctx)
    assert ctx['STATE']=='BRAKING_BURN'
    ctx.update(height=9149,BRAKE_STAGE_DV=0,STATE='COAST')
    fallback=call('_landingBrakeGateInfo',env,ctx)
    for key in ('H_GATE','V_GATE','H_NOW','V_NOW','V_ETA'):assert fallback[key]==old[key]
    print('PASS: reported 505/-3.8m/s, 44.68->2.72m/s2 state reproduces the 152km premature horizontal gate; illustrative 313m/s credit prevents ignition, +/-640m shifts do not change that, and urgent/alignment/zero-credit safeguards remain')


def check_fixed_brake_policy():
    env,ctx=fixture(twr=4,horizontal=400,down=5,height=5000)
    ctx['downrange']=4000
    legacy=call('_landingBrakeGateInfo',env,ctx)
    env['LANDING_ECONOMY_BRAKE']=1
    fixed=call('_landingBrakeGateInfo',env,ctx)
    assert fixed==legacy and fixed['H_NOW']
    site=(ctx['TARGET_LAT'],ctx['TARGET_LNG'])
    control=call('_landingBrakeSteeringInfo',env,ctx)
    assert control['TARGET_VS']<ctx['V_SPEED']
    env['SHIP'].FACING.FOREVECTOR=ctx['steering']
    control=call('_landingBrakeSteeringInfo',env,ctx)
    assert abs(control['THROTTLE']-1)<1e-9
    assert site==(ctx['TARGET_LAT'],ctx['TARGET_LNG'])
    env['LANDING_FLEXIBLE_SITE']=1
    assert not call('_landingBrakeGateInfo',env,ctx)['H_NOW']
    print('PASS: descending full-vector braking preserves a fixed site and all its gates; only explicitly flexible sites suppress geographic ignition')


def descent(credit, flat=False, height=9149, horizontal=504.9, down=3.8, budget=313):
    env,ctx=fixture(gravity=1.6284599,twr=44.68/1.6284599,horizontal=horizontal,down=down,height=height)
    env['LANDING_STAGE_BRAKE_CREDIT']=int(credit)
    env['LANDING_ECONOMY_BRAKE']=int(credit)
    ctx.update(PLAN_ACC=2.72,BRAKE_STAGE_DV=budget)
    ctx['height']=height
    impulse,hover=0.,0.
    ignite=None;staged=False;settle=0
    dt=.2
    for step in range(10000):
        now=step*dt;env['TIME'].SECONDS=now
        effective=1.6284599*(200000/(200000+ctx['height']+5720))**2-ctx['H_SPEED']**2/(200000+ctx['height']+5720)
        ctx['GRAV']=1.6284599 if flat else max(.01,effective)
        env['SHIP'].FACING.FOREVECTOR=ctx.get('steering',ctx['UP_VEC'])
        dispatch={'COAST':'_landingCoastTick','BRAKE_ALIGN':'_landingBrakeAlignTick','BRAKING_BURN':'_landingBrakingTick'}
        call(dispatch[ctx['STATE']],env,ctx)
        if ctx['STATE']=='BRAKING_BURN' and ignite is None:ignite=(now,ctx['height'])
        throttle=ctx.get('throttle',0) if ignite and now>=ignite[0]+3 and now>=settle else 0
        # Exhaust the credited stage by actual thrust impulse, not a fixed
        # staging time. A fresh 3s interruption exceeds the real settle default.
        applied=throttle*ctx['MAX_ACC']*dt
        if not staged:
            applied=min(applied,budget)
            budget-=applied
            ctx['BRAKE_STAGE_DV']=budget
        impulse+=applied
        thrust=ctx.get('steering',ctx['UP_VEC'])*(applied/dt)
        vel=Vec((ctx['H_VEL'][0],0,ctx['V_SPEED']))+(thrust-Vec((0,0,ctx['GRAV'])))*dt
        ctx.update(H_VEL=Vec((vel[0],0,0)),H_SPEED=abs(vel[0]),SURFACE_VEL=vel,
                   V_SPEED=vel[2],DOWN_SPEED=max(0,-vel[2]))
        ctx['height']+=vel[2]*dt;ctx['downrange']-=vel[0]*dt
        assert ctx['height']>100,(credit,ctx)
        if applied>0 and abs(ctx['V_SPEED'])<5 and ctx['height']>1000:hover+=dt
        if not staged and budget<=1e-9:
            staged=True;ctx['MAX_ACC']=2.72;settle=now+3
        if ctx['H_SPEED']<=env['APPROACH_HSPEED']:break
    assert staged and ignite is not None and step<9999
    return dict(ignition=ignite[1],impulse=impulse,hover=hover,height=ctx['height'],
                down=ctx['DOWN_SPEED'],horizontal=ctx['H_SPEED'])


def check_staged_descent():
    old,new=descent(False),descent(True)
    print(f'MODEL horizontal capture: ignite height {old["ignition"]:.0f}->{new["ignition"]:.0f}m; high-hover {old["hover"]:.1f}->{new["hover"]:.1f}s; impulse {old["impulse"]:.1f}->{new["impulse"]:.1f}m/s')
    assert new['ignition']<old['ignition']-500,(old,new)
    assert new['hover']<old['hover']/2 and new['impulse']<old['impulse'],(old,new)
    print('PASS: finite transfer fuel, weak lander, 3s ignition/staging gaps and changing orbital support coast longer with descending control and reduce high-hover time/impulse to horizontal capture in paired point-mass models; no whole-landing/native flight/target precision proof')


def check_surface_gravity_margin():
    # Start only one metre above the staged stopping bound, with full surface
    # gravity throughout, then spend both 3s latency reserves unpowered.
    env,ctx=fixture(gravity=1.6284599,twr=44.68/1.6284599,horizontal=504.9,down=3.8,height=9149)
    envelope=call('lmStagedBrakeEnvelope',env,504.9,3.8,44.68,2.72,313,1.6284599,3,True)
    result=descent(True,flat=True,height=envelope['V']+1)
    flare=call('lmBrakeEnvelope',env,result['horizontal'],result['down'],2.72,1.6284599,3)
    assert result['height']>flare['V'],(result,flare)
    print('PASS: immediate staged-gate entry with full surface gravity, finite transfer impulse and two 3s unpowered gaps retains the weaker-stage flare clearance at horizontal capture')


def check_vector_reserve_geometry():
    rng=random.Random(2239)
    env,_=fixture()
    for _ in range(200):
        grav=rng.uniform(.05,3)
        acc=grav*rng.uniform(1.05,50)
        horizontal,down=rng.uniform(0,600),rng.uniform(0,200)
        future=down+grav*3
        direction=Vec((horizontal,0,future))/math.hypot(horizontal,future)
        limit=call('lmBrakeFullNetAcc',env,horizontal,future,acc,grav)
        reserved=limit*env['LANDING_BRAKE_ACCEL_FRACTION']
        assert reserved>=call('lmBrakeNetAcc',env,acc,grav)-1e-9
        # Independently check the physical vector norm, rather than copying
        # the root formula. No gravity between zero and the surface bound
        # can require more thrust than the engine supplies.
        for effective in (0,grav/4,grav/2,grav*.75,grav):
            demand=direction*reserved+Vec((0,0,effective))
            assert demand.MAG<=acc+1e-9
        full=call('lmFullBrakeEnvelope',env,0,down,acc,grav,3)
        original=call('lmBrakeEnvelope',env,0,down,acc,grav,3)
        assert abs(full['V']-original['V'])<1e-7
    for acc in (0,.5,1.63):
        exact=call('lmFullBrakeEnvelope',env,510,30.8,acc,1.63,3)
        original=call('lmBrakeEnvelope',env,510,30.8,acc,1.63,3)
        assert exact==original and exact['V']>1e8
    print('PASS: 200 reserved net vectors fit physical thrust for every sampled gravity up to the surface bound; pure-vertical and underpowered stopping guards retain their original values')


def check_reported_distance_gate():
    env,ctx=fixture(gravity=1.6284599,twr=44.68/1.6284599,horizontal=510,down=30.8,height=8628)
    env.update(LANDING_STAGE_BRAKE_CREDIT=1,LANDING_ECONOMY_BRAKE=0)
    ctx.update(PLAN_ACC=2.72,BRAKE_STAGE_DV=223.9,downrange=74695)
    conservative=call('_landingBrakeGateInfo',env,ctx)
    assert conservative['H_NOW'] and 74000<conservative['H_GATE']<74500
    assert not conservative['V_NOW'] and abs(conservative['V_ETA']-8.4)<.1
    env['LANDING_ECONOMY_BRAKE']=1
    revised=call('_landingBrakeGateInfo',env,ctx)
    assert not revised['H_NOW'] and not revised['V_NOW'] and revised['V_ETA']>20
    assert 40000<revised['H_GATE']<41000 and 3400<revised['V_GATE']<3500
    call('_landingCoastTick',env,ctx)
    assert ctx['STATE']=='COAST' and ctx['TARGET_THROTTLE']==0
    result=descent(True,flat=True,height=revised['V_GATE']+1,horizontal=510,down=30.8,budget=223.9)
    flare=call('lmBrakeEnvelope',env,result['horizontal'],result['down'],2.72,1.6284599,3)
    assert result['height']>flare['V'],(result,flare)
    # Zero fuel receives no active-stage credit, but still uses only the
    # weaker engine's exact thrust-vector bound in this opt-in full mode.
    ctx['BRAKE_STAGE_DV']=0
    fallback=call('_landingStopEnvelope',env,ctx,510,30.8)
    weak=call('lmFullBrakeEnvelope',env,510,30.8,2.72,1.6284599,3)
    assert fallback==weak
    print('PASS: measured 74.7km/510m/s/223.9m/s-credit snapshot stops the old early H trigger; exact-vector bound keeps 80% reserve and both latency gaps, retains flare clearance from the later gate, and never credits unknown fuel')


if __name__=='__main__':
    check_fuel_credit()
    check_live_stage_cache()
    check_reported_gate()
    check_fixed_brake_policy()
    check_staged_descent()
    check_surface_gravity_margin()
    check_vector_reserve_geometry()
    check_reported_distance_gate()
