"""Tagged post-brake handoff against real source. Not native staging/terrain proof."""
import math
import re
from types import SimpleNamespace as NS
import check_landing_guidance as ks
from check_codebase import ROOT, function_body, closure, dependency_tables
from check_landing_prediction import environment, Vec, independent_inertial_capture
from check_landing_stage_brake import Mixture
from check_runtime_contracts import KList


def fixture():
    env=environment();events=[]
    # Logged starting mass/thrust/exhaust. Retained1.5t and next-stage0.4t
    # propellant are explicit fixture assumptions, NOT recovered native data.
    mass=2.90062952041626;retained=1.5
    fuels=[NS(NAME=n,RATIO=k,DENSITY=.005) for n,k in [('LiquidFuel',.45),('Oxidizer',.55)]]
    def resources(amount):return KList(NS(NAME=f.NAME,AMOUNT=amount*f.RATIO/.005,ENABLED=True) for f in fuels)
    def part(uid,stage,group,mass,modules):
        p=NS(UID=uid,NAME=uid,STAGE=stage,DECOUPLEDIN=group,MASS=mass,MODULES=KList(modules),RESOURCES=KList())
        p.HASMODULE=lambda name:name in p.MODULES
        return p
    def engine(uid,stage,group,thrust,isp,ignition,mass):
        p=part(uid,stage,group,mass,['ModuleEnginesFX'])
        p.IGNITION=ignition;p.FLAMEOUT=False;p.MULTIMODE=False;p.THROTTLELOCK=False
        p.VISP=isp;p.POSSIBLETHRUST=thrust;p.AVAILABLETHRUST=thrust if ignition else 0
        p.POSSIBLETHRUSTAT=lambda pressure:thrust
        p.CONSUMEDRESOURCES=Mixture((f.NAME,f) for f in fuels)
        def activate():p.IGNITION=True;p.AVAILABLETHRUST=thrust
        p.ACTIVATE=activate
        return p
    active=engine('Torch',1,0,55,295,True,.25)
    pair=[engine('lander-'+str(n),0,-1,2,315,False,.02) for n in range(2)]
    core=part('core',-1,-1,.1,['kOSProcessor'])
    legs=[part('leg-'+str(n),-1,-1,.01,['ModuleWheelBase']) for n in range(4)]
    separator=part('lander_decoupler',0,-1,.01,['ModuleDecouple']);separator.STAGED=True;separator.ISDECOUPLED=False
    tank=part('lander-tank',-1,-1,retained-.19,[]);tank.RESOURCES=resources(.4)
    departing=part('transfer-tank',-1,0,mass-retained-.25,[]);departing.RESOURCES=resources(.875914480065912)
    parts=KList([active,*pair,core,*legs,separator,tank,departing])
    bdy=NS(NAME='Minmus',RADIUS=60000,MU=1765800026.31247,ATM=NS(EXISTS=False),ROTATIONPERIOD=40400,POSITION=Vec((0,0,0)))
    ship=NS(NAME='fixture',MASS=mass,BODY=bdy,ALTITUDE=1500,THRUST=55,
        BOUNDS=NS(BOTTOMALTRADAR=1500),PARTS=parts,ENGINES=KList([active,*pair]),
        CONTROL=NS(MAINTHROTTLE=1,PILOTMAINTHROTTLE=0),DELTAV=NS(VACUUM=2078.86),
        ORBIT=NS(ECCENTRICITY=.24),PERIAPSIS=-13900)
    ship.PARTSTAGGED=lambda tag:KList([separator]) if tag=='lander_decoupler' and separator in ship.PARTS else KList()
    env.update(SHIP=ship,CORE=NS(PART=core),STAGE=NS(NUMBER=1,READY=True,DELTAV=NS(VACUUM=1040.0167)),
        HASNODE=False,LANDING_STAGE_LIMIT=0,LANDING_RETURN_DECOUPLER_TAG='',LANDING_RELEASE_DECOUPLER_TAG='lander_decoupler',
        LANDING_RELEASE_AFTER_BRAKE=1,LANDING_STAGE_DISCARD_HSPEED=0,
        LANDING_ECONOMY_BRAKE=1,LANDING_FLEXIBLE_SITE=0,LANDING_POWERED_LEAD=1,
        ORBITAT=lambda *_:NS(BODY=bdy),ETA=NS(PERIAPSIS=100),
        lmGroundGeoAt=lambda _:NS(TERRAINHEIGHT=0))
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',ks.SOURCES):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    env['lmGroundGeoAt']=lambda _:NS(TERRAINHEIGHT=0)
    assert env['vesselLandingPrepareRoles']()
    ctx=dict(STATE='BRAKING_BURN',H_SPEED=17.5,V_SPEED=-30,DOWN_SPEED=30,MAX_ACC=55/mass,
        PLAN_ACC=4/retained,RESERVE_ACC=4/retained,BRAKE_GRAV=bdy.MU/bdy.RADIUS**2,
        HAS_TARGET=True,TARGET_ELEVATION=0,TARGET_LAT=0,TARGET_LNG=0,
        DISCARD_TRIED=False,DISCARD_PENDING=False,DISCARD_SINCE=0,STAGE_UNTIL=0,
        STAGE_ENGINE=-1,STAGE_ACTIVATED=False,STAGE_EVENTS=0,STAGE_WARNED=False,TARGET_THROTTLE=1)
    def stage():
        assert ship.THRUST<=.001 and ship.CONTROL.MAINTHROTTLE==ship.CONTROL.PILOTMAINTHROTTLE==0
        assert ctx['TARGET_THROTTLE']==0
        env['STAGE'].NUMBER=0;separator.ISDECOUPLED=True
        ship.PARTS=KList(p for p in ship.PARTS if p.DECOUPLEDIN<0)
        ship.ENGINES=KList(pair);ship.MASS=retained;ship.DELTAV.VACUUM=1038
        env['STAGE'].DELTAV.VACUUM=1038
        events.append('release')
    env['stage_event']=stage
    return env,ctx,active,pair,separator,events


def check_handoff_and_shared_snapshot():
    env,ctx,active,pair,separator,events=fixture()
    model=env['landingBrakeStack']()
    assert model['VALID'] and len(model['STAGES'])==2,model
    assert model['STAGES'][1]['THRUST']==4 and abs(model['STAGES'][1]['FUEL']-.4)<1e-10
    env['landingStageDisposalTick'](ctx)
    assert ctx['DISCARD_PENDING'] and ctx['TARGET_THROTTLE']==0 and not events
    env['_landingSetThrottle'](ctx,1);assert ctx['TARGET_THROTTLE']==0
    env['TIME'].SECONDS=.1;env['SHIP'].THRUST=0
    env['landingStageDisposalTick'](ctx)
    assert events==['release'] and not ctx['DISCARD_PENDING'] and separator.ISDECOUPLED
    for index in range(2,15):
        env['TIME'].SECONDS=index*.1
        env['vesselStageForLanding'](ctx)
        env['landingStageDisposalTick'](ctx)
    assert all(p.IGNITION for p in pair) and events==['release']
    assert env['CORE'].PART in env['SHIP'].PARTS
    after=env['landingBrakeStack']()
    assert after['VALID'] and len(after['STAGES'])==1 and after['STAGES'][0]['THRUST']==4
    assert abs(after['STAGES'][0]['FUEL']-.4)<1e-10
    print('PASS: actual tagged1->0 release waits for zero, stays pending across publishers, retains core/legs, activates both engines once; shared fuel counted once before/after separation')


def check_refusals():
    for fault in ('floor','duplicate','tag','core','leg','slot','reserve','height','ascent','orbit','unbound','abort','thrust','timeout','different-isp','different-mixture'):
        env,ctx,active,pair,separator,events=fixture()
        if fault=='floor':env['LANDING_STAGE_LIMIT']=1
        if fault=='duplicate':env['SHIP'].PARTSTAGGED=lambda _:KList([separator,separator])
        if fault=='tag':env['LANDING_RELEASE_DECOUPLER_TAG']='missing'
        if fault=='core':env['CORE'].PART.DECOUPLEDIN=0
        if fault=='leg':next(p for p in env['SHIP'].PARTS if p.UID=='leg-0').DECOUPLEDIN=0
        if fault=='slot':separator.MODULES.ADD('ModuleParachute')
        if fault=='reserve':env['SHIP'].DELTAV.VACUUM=1100
        if fault=='height':env['SHIP'].BOUNDS.BOTTOMALTRADAR=100
        if fault=='ascent':ctx['V_SPEED']=10
        if fault=='orbit':env['SHIP'].PERIAPSIS=1000
        if fault=='unbound':env['SHIP'].ORBIT.ECCENTRICITY=1.1
        if fault=='abort':env['ABORT']=True
        if fault=='different-isp':pair[1].VISP=300
        if fault=='different-mixture':pair[1].CONSUMEDRESOURCES=Mixture([('x',NS(NAME='MonoPropellant',RATIO=1,DENSITY=.004))])
        if fault in ('different-isp','different-mixture'):
            assert not env['landingBrakeStack']()['VALID'];continue
        env['landingStageDisposalTick'](ctx)
        if fault in ('thrust','timeout'):
            assert ctx['DISCARD_PENDING']
            env['TIME'].SECONDS=.1 if fault=='thrust' else 1.1
            env['landingStageDisposalTick'](ctx)
        assert not events and all(not p.IGNITION for p in pair),fault
    print('PASS: floor/return hardware, duplicate/missing tag, CPU/leg loss, unsafe slot, fuel/clearance/orbit/Abort/cutoff/timeout and incompatible engine-group refusals preserve hardware')


def check_gate_reserves_weak_flare():
    env,ctx,*_=fixture()
    envelope=env['lmReleaseBrakeEnvelope'](150,34,ctx['MAX_ACC'],ctx['PLAN_ACC'],ctx['BRAKE_GRAV'],3)
    ordinary=env['lmFullBrakeEnvelope'](150,34,ctx['MAX_ACC'],ctx['BRAKE_GRAV'],3)
    assert envelope['V']>ordinary['V']+500,(envelope,ordinary)
    print('PASS: first burn reserves the slower lander flare before releasing a still-fueled transfer stage; reserve is not based on the discarded55kN engine')


def check_complete_release_forecast():
    env,ctx,*_=fixture()
    stack=env['landingBrakeStack']()
    pos=Vec((65000,0,0));vel=Vec((-34,0,150))
    result=env['landingPredictBrake'](pos,vel,stack,0,1)
    assert result['VALID'],result
    assert result['STAGES_USED']==2 and result['MASS']<1.5
    assert result['HS']<=env['TERMINAL_HSPEED'] and result['HEIGHT']<=env['TERMINAL_ALT']
    assert stack['STAGES'][0]['FUEL']>.8 # Neither stage snapshot mutated.
    # No safe handoff at the surface; do not let the strong discarded motor
    # falsely certify a terminal capture before validating the weak flare.
    bad=env['landingPredictBrake'](Vec((60100,0,0)),Vec((-34,0,10)),stack,0,1)
    assert not bad['VALID'] and bad['REASON']=='tagged-release-clearance',bad
    print('PASS: full source Minmus forecast actually discards unused transfer propellant, switches to the matched pair and captures with retained mass; low-altitude handoff cannot pass via strong-engine capture')


def check_release_independent_physics():
    env,ctx,*_=fixture()
    stack=env['landingBrakeStack']()
    pos=Vec((65000,0,0));vel=Vec((-34,0,150))
    model=env['landingPredictBrake'](pos,vel,stack,0,.5)
    reference,seconds,mass=independent_inertial_capture(env,stack,pos,vel,dt=.25,elevation=0)
    assert model['VALID'] and (model['POSITION']-reference).MAG<50
    assert abs(model['SECONDS']-seconds)<2 and abs(model['MASS']-mass)<.001
    print('PASS: tagged main-burn/weak-flare forecast agrees within50m/2s/1kg with inertial RK4 physics and independent unused-fuel/dry-mass disposal, under explicit flat-terrain/ideal-attitude assumptions')


def check_wreck_rejection():
    env,ctx,*_=fixture()
    required=env['_landingRequiredHardware']()
    assert len(required)==5 and env['_landingHardwareIntact'](required)
    # Intended transfer release is okay; a missing retained leg is not.
    env['SHIP'].PARTS=KList(p for p in env['SHIP'].PARTS if p.DECOUPLEDIN<0)
    assert env['_landingHardwareIntact'](required)
    env['SHIP'].PARTS=KList(p for p in env['SHIP'].PARTS if p.UID!='leg-0')
    assert not env['_landingHardwareIntact'](required)
    finish=function_body(ks.SOURCES,'_landingFinish')
    assert finish.index('_landingHardwareIntact')<finish.index('stateSet("landing_lat"')
    assert 'IF NOT landExecute() { RETURN FALSE. }' in function_body(ks.SOURCES,'landingAssistStage')
    print('PASS: intentional transfer disposal retains required identities; surviving CPU with a lost leg fails touchdown success and cannot advance to surface science')


if __name__=='__main__':
    check_handoff_and_shared_snapshot()
    check_refusals()
    check_gate_reserves_weak_flare()
    check_complete_release_forecast()
    check_release_independent_physics()
    check_wreck_rejection()
