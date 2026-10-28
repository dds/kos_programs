"""Native low-parking regression with independent two-body apsis physics.

Executes real SHAPE seed, floor, cost, minimum, budget and phase logic.
No numerical optimizer, attitude dynamics, plane/AoP maneuver or kOS VM.
"""
import math
from types import SimpleNamespace as NS

from check_codebase import ROOT
from check_shape_precision import execute, phase_fixture
from check_shape_minimum import Lex, Skip
from check_surface_return import defaults, read_settings, emit_profile


class Zero(int):
    def ISTYPE(self, _):return False


class Number(float):
    def __radd__(self, other):
        return other+str(float(self)) if isinstance(other,str) else other+float(self)


def fixture():
    env,_,removed,events=phase_fixture()
    env.update(SQRT=math.sqrt,MAX=max,SHAPE_MIN_PE=10000,SHAPE_MIN_BURN_DV=.002,
        SHAPE_ALT_TOL=100,SHAPE_BURN_TOLERANCE=.001,BURN_TRIM_ABS_COMPLETE_DV=.05,
        BURN_TRIM_COMPLETE_MAX_DV=.05,TIME=NS(SECONDS=4218532),
        SHAPE_DV_CAP=150,SHAPE_TOTAL_DV_CAP=250,SHAPE_RESERVE_DV=300,
        LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])))
    ship=env['SHIP'];ship.STATUS='ORBITING'
    ship.BODY=NS(NAME='Minmus',MU=1765800026.31247,RADIUS=60000,ATM=NS(EXISTS=False))
    ship.PERIAPSIS=9520;ship.APOAPSIS=10031
    ship.DELTAV=NS(VACUUM=986)
    ship.ORBIT.ARGUMENTOFPERIAPSIS=110.3
    targets=Lex(AP=659734,PE=554472)
    budget={};burns=[]
    def refresh():
        rp=60000+ship.PERIAPSIS;ra=60000+ship.APOAPSIS
        ship.ORBIT.SEMIMAJORAXIS=(rp+ra)/2
        ship.ORBIT.ECCENTRICITY=(ra-rp)/(ra+rp)
    refresh()
    def radius(ta):return 60000+(ship.PERIAPSIS if ta==0 else ship.APOAPSIS)
    def speed(ta):return math.sqrt(ship.BODY.MU*(2/radius(ta)-1/ship.ORBIT.SEMIMAJORAXIS))
    def orbit(rb,velocity):
        # Energy and angular momentum determine the second radial turning
        # point. Sort it: a burn above circular speed swaps which apsis stays.
        sma=1/(2/rb-velocity**2/ship.BODY.MU)
        far=2*sma-rb
        return NS(PERIAPSIS=min(rb,far)-60000,APOAPSIS=max(rb,far)-60000,
            ECCENTRICITY=abs(rb-far)/(rb+far),INCLINATION=3.029,LAN=90,
            ARGUMENTOFPERIAPSIS=110.3)
    def node(ut,radial,normal,prograde):
        ta=0 if env['burnTa']==0 else 180
        rb=radius(ta);vnow=speed(ta)
        return NS(TIME=ut,ETA=ut-env['TIME'].SECONDS,RADIALOUT=radial,NORMAL=normal,
            PROGRADE=prograde,DELTAV=NS(MAG=abs(prograde)),ORBIT=orbit(rb,vnow+prograde),rb=rb,vnow=vnow)
    def call(name,**params):return execute(name,dict(env,**params))
    def plan(eta,ta,alt,label):
        env['burnTa']=ta
        return call('_planTangentBurnAt',burnEta=eta,burnTa=ta,targetAlt=alt,label=label)
    def cost(nd,label,target):
        return call('_burnCostOf',o=nd.ORBIT,label=label,targets=target,
            dvMag=nd.DELTAV.MAG,seedDv=max(5,nd.DELTAV.MAG),
            peNow=ship.PERIAPSIS,apNow=ship.APOAPSIS,nNow=0)
    def apsis(eta,ta,alt,label,target):
        result=call('_apsisBurn',burnEta=eta,burnTa=ta,targetAlt=alt,label=label,targets=target)
        return Zero(0) if result==0 else Skip(result) if isinstance(result,str) else result
    env.update(NODE=node,fixture_add=lambda nd:env.update(NEXTNODE=nd,HASNODE=True),
        _radiusAtTa=radius,_speedAtTa=speed,maneuverUiArchiveLog=lambda _:None,
        _peFloor=lambda:call('_peFloor'),_shapeRepairPeriapsis=lambda target:call('_shapeRepairPeriapsis',targets=target),
        _planTangentBurnAt=plan,_apsisBurn=apsis,
        _finishShapeNode=lambda nd,label,target:call('_finishShapeNode',nd=nd,label=label,targets=target),
        _refineBurnNode=cost,_burnCostNow=cost,
        _nodeUnsafe=lambda nd:call('_nodeUnsafe',nd=nd),_nodeWrecksPlane=lambda _:False,
        planeNormalFromIncLan=lambda *_:0,VANG=lambda a,b:abs(a-b),
        shapeErrors=lambda target:Lex(AP=ship.APOAPSIS-target['AP'],PE=ship.PERIAPSIS-target['PE']),
        shapeConverged=lambda target:call('shapeConverged',targets=target),
        shapeTargetsWithPrefix=lambda _:targets,shapeNextBurn=lambda target:call('shapeNextBurn',targets=target),
        stateGet=lambda key,default='':budget.get(key,default),stateGetNum=lambda key,default=0:Number(budget.get(key,default)),
        stateSet=lambda key,value:budget.update({key:value}))
    def burn():
        nd=env['NEXTNODE'];tol=env['BURN_TRIM_ABS_COMPLETE_DV']
        achieved=orbit(nd.rb,nd.vnow+math.copysign(max(0,nd.DELTAV.MAG-tol),nd.PROGRADE))
        assert nd.ORBIT.PERIAPSIS>=10000 and achieved.PERIAPSIS>=10000
        ship.PERIAPSIS,ship.APOAPSIS=achieved.PERIAPSIS,achieved.APOAPSIS
        ship.DELTAV.VACUUM-=nd.DELTAV.MAG;refresh()
        assert ship.DELTAV.VACUUM>=300
        burns.append(nd.DELTAV.MAG);env['HASNODE']=False
        return True
    env.update(executeManeuver=burn,_shapeReserveBurn=lambda nd:call('_shapeReserveBurn',nd=nd))
    return env,targets,events,burns,call


def check_native_low_parking():
    env,targets,events,burns,call=fixture()
    original=targets.copy()
    first=call('shapeNextBurn',targets=targets)
    assert first['label']=='set-pe-for-ap' and 55<first['node'].DELTAV.MAG<56
    assert 10000<first['node'].ORBIT.PERIAPSIS<=env['SHIP'].APOAPSIS+.001
    assert abs(first['node'].ORBIT.APOAPSIS-targets['AP'])<.001
    assert targets==original # Repair objective cannot replace the contract.
    env['HASNODE']=False
    execute('_runShapePhase',env)
    assert len(burns)==2 and 55<burns[0]<56 and sum(burns)<100,burns
    assert abs(env['SHIP'].APOAPSIS-659734)<=100 and abs(env['SHIP'].PERIAPSIS-554472)<=100
    assert events.count('advance')==1 and 'hold' not in events
    # If no high Ap raise is requested, the small standalone repair remains
    # available through exactly the same admission/quality/minimum gates.
    env,_,_,_,call=fixture()
    small=call('shapeNextBurn',targets=Lex(AP=10031,PE=10015))
    assert small['label']=='floor-pe' and .25<small['node'].DELTAV.MAG<.35
    print('PASS: native9.520x10.031km parking uses one legal~55.8m/s Ap raise from current Ap instead of a separate tiny repair; actual SHAPE seeds/costs/budgets reach both requested apsides in two burns with1mm/s residuals; optional~0.28m/s repair remains, plane/AoP separate')


def check_repair_rejections_and_handoff():
    for fault in ('low-ap','suborbital','negative-pe','hyperbolic','nan-conic','atmosphere','coarse-execution','minimum','budget'):
        env,targets,events,burns,call=fixture()
        if fault=='low-ap':env['SHIP'].APOAPSIS=9999
        if fault=='suborbital':env['SHIP'].STATUS='SUB_ORBITAL'
        if fault=='negative-pe':env['SHIP'].PERIAPSIS=-1
        if fault=='hyperbolic':env['SHIP'].ORBIT.ECCENTRICITY=1
        if fault=='nan-conic':env['SHIP'].ORBIT.ECCENTRICITY=float('nan')
        if fault=='atmosphere':
            env['SHIP'].BODY.ATM=NS(EXISTS=True,HEIGHT=70000)
            env['SHIP'].PERIAPSIS=69000;env['SHIP'].APOAPSIS=85000
        if fault=='coarse-execution':env['SHAPE_BURN_TOLERANCE']=-1
        if fault=='minimum':env['SHAPE_MIN_BURN_DV']=100
        if fault=='budget':env['SHIP'].DELTAV.VACUUM=300
        execute('_runShapePhase',env)
        assert not burns and [event for event in events if not isinstance(event,tuple)]==['hold'],(fault,burns,events)
    for orbit,requested,expected in (({},10000,10000),({'MIN_PE':10000},10000,11000),
                                     ({'MIN_PE':9000},10000,10000),({'MIN_PE':10000},25000,25000)):
        cfg=defaults();cfg.update(SURFACE_RETURN_ORBIT=orbit,SURFACE_RETURN_PARKING_ALT=requested,
            SURFACE_RETURN_SEQUENCE=['PRELAUNCH','LAUNCH','PARK','SHAPE','RETURN_SETUP'],
            BODY_NAME='MINMUS',PARKING_ALT=requested,LAUNCH_INCLINATION=0,LAUNCH_AZIMUTH=90)
        generated=read_settings(emit_profile('phaseSurfaceReturnSetup',cfg),defaults())
        assert generated['PARKING_ALT']==expected
    # Worst tangential0.3m/s circularization residual at11km is still above
    # the10km SHAPE floor. Independent two-body reference, not a flight promise.
    radius=71000;mu=1765800026.31247;speed=math.sqrt(mu/radius)-.3
    pe=2/(2/radius-speed**2/mu)-radius-60000
    assert pe>10000,pe
    print('PASS: no headroom, suborbital/invalid conic, coarse residual or insufficient reserve hold without burning; generated shaped ascents use11km while ordinary10km returns and higher/custom-floor parking stay unchanged')


if __name__=='__main__':
    check_native_low_parking()
    check_repair_rejections_and_handoff()
