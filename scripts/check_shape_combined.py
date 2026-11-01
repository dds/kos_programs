"""Joint apsis impulse against independent Cartesian conics, not native KSP."""
import math
import re
from types import SimpleNamespace as NS

import check_relay_constellation as harness
import check_survey_orbit as physics
import check_shape_minimum as ordering
import check_espoir_fleet as fleet
from check_codebase import ROOT
from check_espoir_fleet import Text, Items, native

SOURCE=(ROOT/'lib/orbit_shape.ks').read_text().replace('ADD nd.','fixture_add(nd).').replace('REMOVE NEXTNODE.','fixture_remove(NEXTNODE).')


def fixture():
    env,ship,saved,events,nodes,_,_=physics.fixture(inc=180)
    bdy=ship.BODY;bdy.NAME=Text('Mun');bdy.RADIUS=200000;bdy.MU=6.5138398e10;bdy.SOIRADIUS=2429559
    rp=213730;ra=1937030;epoch=env['TIME'].SECONDS+4000
    speed=math.sqrt(bdy.MU*(2/ra-2/(rp+ra)))
    ship.ORBIT=physics.Orbit(bdy,(ra,0,0),(0,-speed,0),epoch)
    targets=harness.Record([('AP',1737680),('PE',1543150),('INC',180)])
    env.update(SHAPE_MIN_PE=10000,SHAPE_ALT_TOL=500,SHAPE_ANG_TOL=.1,SHAPE_AOP_TOL=.5,
        SHAPE_MIN_BURN_DV=.002,SHAPE_BURN_TOLERANCE=.001,SHAPE_DV_CAP=600,SHAPE_TOTAL_DV_CAP=1800,
        SHAPE_RESERVE_DV=400,_shapeMinimumSkipped=False,MAX_SHAPE_BURNS=12,MAX_RETRIES=5,
        BURN_TRIM_ABS_COMPLETE_DV=.05,BURN_TRIM_COMPLETE_MAX_DV=.05,
        ETA=NS(APOAPSIS=4000,PERIAPSIS=17726),NEAR_CIRC_ECC=.01,MIN_AOP_TARGET_ECC=.004,
        phaseShouldYield=False,phaseLabel=Text('SHAPE'),prefix=Text('SHAPE_'),
        _targetSummary=lambda _:Text(''),_errorSummary=lambda _:Text(''),orbitSummary=lambda:None,
        LEX=lambda *xs:harness.Record(zip(xs[::2],xs[1::2])),
        planeNormalFromIncLan=lambda *_:0,_planeErrOf=lambda *_:0,
        mLogError=lambda row:events.append(str(row)),
        yieldToPrompt=lambda:events.append('hold'),nextPhase=lambda _:events.append('advance'),xferSeq=Items())
    saved.update(phase=Text('SHAPE'),shape_budget_id=Text('Mun:100'),shape_budget_spent=25)
    env['_speedAtTa']=lambda ta:math.sqrt(bdy.MU*(2/(bdy.RADIUS+(ship.APOAPSIS if ta==180 else ship.PERIAPSIS))-1/ship.ORBIT.SEMIMAJORAXIS))
    env['shapeTargetsWithPrefix']=lambda _:targets
    env['shapeErrors']=lambda _:harness.Record([('AP',ship.APOAPSIS-targets['AP']),('PE',ship.PERIAPSIS-targets['PE']),('PLANE',abs(ship.ORBIT.INCLINATION-180))])
    for name in ('_peFloor','_shapeCombinedOwned','_shapeCombinedApsides','_nodeUnsafe','_shapeNodeAboveMinimum',
                 'shapeNextBurn','shapeConverged','_runShapePhase','_shapeInterruptedHold','_shapePlanningReady',
                 '_shapeNodeTimingReady','_shapeReserveBurn'):
        def call(*args,name=name):
            result=harness.invoke(SOURCE,name,env,*args)
            return native(0) if result==0 and name=='_shapeCombinedApsides' else result
        env[name]=call
    def no_fallback(*_):raise AssertionError('Joint solution fell through to separate tiny burn')
    env.update(_apsisBurn=no_fallback,planPlaneMatch=no_fallback,maneuverBurnInterrupted=lambda:False,
        orbitBurnRecover=lambda *_:False)
    return env,ship,saved,targets,events,nodes


def check_native_scalar_scenario():
    env,ship,saved,targets,events,nodes=fixture();burns=[]
    def burn():
        nd=env['NEXTNODE'];assert nd.DELTAV.MAG>90 and nd.ETA<17501
        burns.append(nd.DELTAV.MAG)
        # Independent applied vector misses by the configured1mm/s budget.
        scale=(nd.DELTAV.MAG-.001)/nd.DELTAV.MAG
        achieved=physics.Node(env,nd.TIME,nd.RADIALOUT*scale,nd.NORMAL,nd.PROGRADE*scale).ORBIT
        ship.ORBIT=achieved;env['TIME'].SECONDS=nd.TIME
        env['fixture_remove'](nd);return True
    env['executeManeuver']=burn
    env['_runShapePhase'](Text('SHAPE'),Text('SHAPE_'))
    assert len(burns)==1 and 96<burns[0]<98 and events[-1]=='advance'
    assert abs(ship.APOAPSIS-targets['AP'])<500 and abs(ship.PERIAPSIS-targets['PE'])<500
    assert abs(saved['shape_budget_spent']-25-burns[0])<1e-8
    print('PASS: actual SHAPE pipeline replaces0.0124m/s/17501s precursor with one~96.8m/s/4000s joint impulse, preserves1mm/s execution precision,500m goals and cumulative budget')


def check_geometry_and_quality_guards():
    for fault in ('aop','radius-outside','extra-cost','native-patch','native-error','plane','minimum','abort','foreign'):
        env,ship,saved,targets,events,nodes=fixture()
        if fault=='aop':targets['AOP']=34.3
        if fault=='radius-outside':targets['PE']=ship.APOAPSIS+1
        if fault=='extra-cost':targets['AP']=ship.APOAPSIS+500000
        if fault=='plane':env['_planeErrOf']=lambda *_:1
        if fault=='minimum':env['SHAPE_MIN_BURN_DV']=500
        if fault=='abort':env['ABORT']=True
        if fault=='foreign':env.update(HASNODE=True,NEXTNODE=NS())
        if fault in ('native-patch','native-error'):
            class Wrong(physics.Node):
                @property
                def ORBIT(self):
                    orb=super().ORBIT
                    if fault=='native-patch':orb.HASNEXTPATCH=True
                    else:orb.SEMIMAJORAXIS+=100000
                    return orb
            env['NODE']=lambda *args:Wrong(env,*args)
        before=saved.copy()
        assert not env['_shapeCombinedApsides'](targets),fault
        assert saved==before and not any(n.alive for n in nodes),fault
    print('PASS: AoP contracts, unreachable geometry, >0.05m/s extra cost, unsafe/inaccurate native predictions, plane drift, minimum, Abort and foreign-node safeguards reject the joint option without spending budget')


def check_contract_order_and_final_tolerances():
    # Prescribed measured errors, with optimizer responses supplied separately:
    # this proves the actual selector's order, not native AoP propagation.
    env,_,_=ordering.fixture();cfg=fleet.profile('mun_contract_survey_return')
    # Preserve the generic stricter500m ordering regression independently of
    # this mission's operator-requested1km acceptance policy.
    env.update(cfg,SHAPE_AOP_TOL=.5,SHAPE_ALT_TOL=500)
    targets=ordering.Lex(AP=cfg['SHAPE_AP'],PE=cfg['SHAPE_PE'],INC=cfg['SHAPE_INC'],AOP=cfg['SHAPE_AOP'])
    ship=env['SHIP'];ship.APOAPSIS=1737030;ship.PERIAPSIS=13730
    ship.ORBIT.ECCENTRICITY=.8012;ship.ORBIT.INCLINATION=179.967
    errors=ordering.Lex(AP=-650,PE=13730-1543150,PLANE=.033,AOP=31-34.3)
    env.update(targets=targets,shapeErrors=lambda _:errors,peFloor=10000)
    calls=[];node=NS(DELTAV=NS(MAG=96))
    def apsis(*args):calls.append(args[3]);return ordering.Lex(node=node,label=args[3])
    def aop(*args):calls.append(('aop',args));return node
    env.update(_apsisBurn=apsis,planAoPChange=aop,
               _finishShapeNode=lambda nd,label,goals:ordering.Lex(node=nd,label=label))
    assert ordering.execute('shapeNextBurn',env)['label']=='set-pe'
    assert calls==['set-pe'] and not ordering.execute('shapeConverged',env)
    # Raising Pe lowers eccentricity before paying for an apsidal rotation.
    ship.PERIAPSIS=targets['PE'];ship.ORBIT.ECCENTRICITY=.053;errors['PE']=0;calls.clear()
    assert ordering.execute('shapeNextBurn',env)['label']=='aop'
    assert calls==[('aop',(34.3,.5))] and not ordering.execute('shapeConverged',env)
    errors['AOP']=0;calls.clear()
    assert ordering.execute('shapeNextBurn',env)['label']=='set-ap'
    assert calls==['set-ap'] and not ordering.execute('shapeConverged',env)
    errors['AP']=0
    assert ordering.execute('shapeConverged',env)
    # A large AP change still precedes rotation; the extra ordering margin
    # can never make a650m error count as a500m goal success.
    ship.APOAPSIS=targets['AP']+5000
    errors.update(AP=5000,AOP=-3.3);calls.clear()
    assert ordering.execute('shapeNextBurn',env)['label']=='set-ap' and calls==['set-ap']
    env['SHAPE_ALT_TOL']=cfg['SHAPE_ALT_TOL']
    errors.update(AP=-623.9228707,PE=82.34217653,AOP=.075);calls.clear()
    assert cfg['SHAPE_ALT_TOL']==1000 and ordering.execute('shapeConverged',env)
    assert ordering.execute('shapeNextBurn',env)==0 and not calls
    print('PASS: generic500m planner retains Pe->AoP->Ap priority and strict convergence; this mission1km policy accepts native624m Ap/82m Pe/.075deg AoP without the pointless0.015m/s trim')


def check_aop_contract_deadband():
    source=(ROOT/'lib/maneuver_plan.ks').read_text().replace('ADD nd.','fixture_add(nd).')
    env,ship,_,_,_,nodes=fixture()
    ship.ORBIT.ARGUMENTOFPERIAPSIS=31
    env['etaToTrueAnomaly']=lambda ta:100+ta
    env['maneuverUiArchiveLog']=lambda _:None
    assert harness.invoke(source,'planAoPChange',env,31.8)==0 and not nodes
    nd=harness.invoke(source,'planAoPChange',env,31.8,.5)
    assert nd.DELTAV.MAG>0 and nd.ETA>=60 and nd.NORMAL==0 and nd.PROGRADE==0
    env['fixture_remove'](nd)
    assert harness.invoke(source,'planAoPChange',env,31.2,.5)==0
    print('PASS: actual AoP planner accepts required0.8deg correction at SHAPE0.5deg tolerance, preserves its two-degree generic default and does not create an already-in-tolerance node')


def check_minmus_aop_before_tiny_cleanup():
    env,_,_=ordering.fixture();cfg=fleet.profile('minmus_orbital_surveyor')
    env.update(cfg);ship=env['SHIP']
    ship.PERIAPSIS=469698.432992394;ship.APOAPSIS=1034646.10850534
    rp=ship.BODY.RADIUS+ship.PERIAPSIS;ra=ship.BODY.RADIUS+ship.APOAPSIS
    ship.ORBIT.ECCENTRICITY=(ra-rp)/(ra+rp)
    targets=ordering.Lex(AP=cfg['SHAPE_AP'],PE=cfg['SHAPE_PE'],AOP=cfg['SHAPE_AOP'])
    errors=ordering.Lex(AP=ship.APOAPSIS-targets['AP'],PE=ship.PERIAPSIS-targets['PE'],
                        PLANE=.001,AOP=-71.227)
    calls=[];node=NS(DELTAV=NS(MAG=20.15))
    env.update(targets=targets,shapeErrors=lambda _:errors)
    env['planAoPChange']=lambda *args:calls.append(('aop',args)) or node
    env['_finishShapeNode']=lambda nd,label,goals:ordering.Lex(node=nd,label=label)
    env['_apsisBurn']=lambda *args:calls.append(args[3]) or ordering.Lex(node=node,label=args[3])
    assert ordering.execute('shapeNextBurn',env)['label']=='aop'
    assert calls==[('aop',(157.3,.2))] and not ordering.execute('shapeConverged',env)
    # Independent Cartesian states at the intersection of equal-size,
    # rotated ellipses prove the physical rotation/size cost hierarchy.
    # This is not the game's node radial basis or a finite-burn simulation.
    mu=ship.BODY.MU;ecc=ship.ORBIT.ECCENTRICITY;p=2*rp*ra/(rp+ra)
    half=math.radians(71.227/2);radius=p/(1+ecc*math.cos(half))
    position=(radius,0,0);speed=math.sqrt(mu/p)
    before=(speed*ecc*math.sin(half),speed*(1+ecc*math.cos(half)),0)
    after=(-before[0],before[1],0)
    original=physics.Orbit(ship.BODY,position,before,0)
    rotated=physics.Orbit(ship.BODY,position,after,0)
    assert abs(original.APOAPSIS-rotated.APOAPSIS)<1e-7
    assert abs(original.PERIAPSIS-rotated.PERIAPSIS)<1e-7
    angle=math.degrees(math.acos(physics.dot(original.p,rotated.p)))
    assert abs(angle-71.227)<1e-9
    rotation_dv=physics.norm(physics.add(after,physics.mul(before,-1)))
    def tangent(radius,far):return math.sqrt(mu*(2/radius-2/(radius+far)))
    ap_dv=abs(tangent(rp,ship.BODY.RADIUS+targets['AP'])-tangent(rp,ra))
    pe_dv=abs(tangent(ra,ship.BODY.RADIUS+targets['PE'])-tangent(ra,rp))
    assert .063<ap_dv<.064 and .14<ap_dv+pe_dv<.15 and 20<rotation_dv<21
    # Every final element remains mandatory: after AoP, execute apsis trims
    # even though their costs are small. No minimum/tolerance waiver.
    errors['AOP']=0;calls.clear()
    assert ordering.execute('shapeNextBurn',env)['label']=='set-ap' and calls==['set-ap']
    errors['AP']=0;calls.clear()
    assert ordering.execute('shapeNextBurn',env)['label']=='set-pe' and calls==['set-pe']
    errors['PE']=0
    assert ordering.execute('shapeConverged',env)
    print('PASS: measured Minmus6.4km/3.9km apsis errors cost~0.145m/s versus~20.14m/s for71.227deg rotation; actual selector prioritizes AoP then both required trims with500m/.2deg goals unchanged')


def check_apsis_order_cost_guards():
    env,_,_=ordering.fixture();ship=env['SHIP']
    ship.PERIAPSIS=469698.432992394;ship.APOAPSIS=1034646.10850534
    goals=ordering.Lex(AP=1041045,PE=465764)
    cheap=env['_shapeCheapApsisCleanup']
    assert cheap(goals,71.227) and cheap(goals,-71.227)
    # Tolerances and minimums cannot affect this ordering-only estimate.
    env.update(SHAPE_ALT_TOL=.001,SHAPE_MIN_BURN_DV=100)
    assert cheap(goals,71.227)
    assert not cheap(goals,.01) and not cheap(goals,0)
    for targets in (ordering.Lex(AP=ship.PERIAPSIS-1),ordering.Lex(PE=ship.APOAPSIS+1),
                    ordering.Lex(PE=-60000),ordering.Lex(AP=math.nan)):
        assert not cheap(targets,71.227),targets
    assert cheap(ordering.Lex(AP=1041045),71.227)
    assert cheap(ordering.Lex(PE=465764),71.227)
    for field,value in (('MU',0),('MU',math.nan),('MU',math.inf)):
        prior=getattr(ship.BODY,field);setattr(ship.BODY,field,value)
        assert not cheap(goals,71.227);setattr(ship.BODY,field,prior)
    ship.PERIAPSIS=ship.APOAPSIS=70000
    assert not cheap(ordering.Lex(AP=90000,PE=70000),71.227)
    print('PASS: cheap-cleanup estimate handles both rotation signs/partial goals, ignores acceptance tolerances, and refuses invalid geometry, nonfinite/zero gravity, circular rotation and insignificant AoP changes; major resize ordering remains covered')


if __name__=='__main__':
    check_native_scalar_scenario()
    check_geometry_and_quality_guards()
    check_contract_order_and_final_tolerances()
    check_aop_contract_deadband()
    check_minmus_aop_before_tiny_cleanup()
    check_apsis_order_cost_guards()
