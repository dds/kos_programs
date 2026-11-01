"""Operational orbit accuracy from independent impulses; not a KSP/kOS run."""
import math

import check_espoir_fleet as fleet
import check_landing_orbit as prep
import check_shape_minimum as ordering
import check_survey_orbit as physics
from check_relay_constellation import invoke


SOURCE=prep.SHAPE


def accuracy_fixture(body='Minmus'):
    env,ship,_,events,_,_,_=physics.fixture(body=body)
    ship.MASS=1.287
    if body=='Mun':
        ship.BODY.RADIUS=200000;ship.BODY.MU=6.5138398e10
    env['BURN_TRIM_ABS_COMPLETE_DV']=.05
    return env,ship,events


def tolerance(env,targets,base=250,minimum=.1):
    return invoke(SOURCE,'shapeOperationalAltitudeTolerance',env,fleet.native(targets),base,minimum)


def check_authority_and_independent_sensitivity():
    for body,height in (('Minmus',15000),('Mun',15000),('Kerbin',100000),('Duna',70000)):
        env,ship,_=accuracy_fixture(body);mu=ship.BODY.MU;radius=ship.BODY.RADIUS+height
        goals=ordering.Lex(AP=height,PE=height)
        # Cartesian conic reconstruction supplies sensitivity independently
        # of the source's differentiated vis-viva expression.
        speed=math.sqrt(mu/radius);step=1e-5
        orb=physics.Orbit(ship.BODY,(radius,0,0),(0,speed,0),0)
        changed=physics.Orbit(ship.BODY,(radius,0,0),(0,speed+step,0),0)
        sensitivity=(changed.APOAPSIS-orb.APOAPSIS)/step
        resolved=[]
        for acceleration in (.5,20,200):
            ship.AVAILABLETHRUST=acceleration*ship.MASS
            actual=tolerance(env,goals);resolved.append(actual)
            expected=max(250,min(.1*height,max(.1,.05,acceleration*.02)*sensitivity))
            assert abs(actual-expected)<.01,(body,actual,expected)
            assert 250<=actual<=.1*height
        assert resolved==sorted(resolved) and resolved[-1]>resolved[0]
        # Live high-eccentricity capture changes do not inflate the target
        # accuracy corridor: it is derived from the requested orbit.
        prior=tolerance(env,goals)
        original=ship.ORBIT
        ship.ORBIT=type('Live',(),dict(APOAPSIS=height+1000000,PERIAPSIS=height+400))()
        assert tolerance(env,goals)==prior
        ship.ORBIT=original
    print('PASS: operational accuracy matches independent Cartesian impulse sensitivity on Minmus/Mun/Kerbin/Duna, increases with motor authority, stays bounded to10% of target altitude, and ignores changing capture geometry')


def check_reported_high_capture_transition():
    cfg=fleet.profile('minmus_contract_lander_return')
    env,saved,events,nodes,refresh=prep.fixture(False);env.update(cfg)
    env['xferSeq']=env['launchSeq']=prep.Seq(cfg['SEQUENCE'])
    saved['mission_id']=cfg['MISSION_ID']
    ship=env['SHIP'];ship.PERIAPSIS=15600;ship.APOAPSIS=1050800
    ship.ORBIT.INCLINATION=89.99;ship.ORBIT.LAN=76.3742076925968
    ship.DELTAV.VACUUM=2155.864;env['STAGE'].DELTAV.VACUUM=1117.018
    rp=ship.BODY.RADIUS+ship.PERIAPSIS;ra=ship.BODY.RADIUS+ship.APOAPSIS
    expected_dv=math.sqrt(ship.BODY.MU*(2/rp-2/(rp+ra)))-math.sqrt(ship.BODY.MU/rp)
    refresh();goals=env['landingPrepTargets']()
    # The old500m corridor still cannot be declared complete or executed
    # through a sub-minimum Pe trim. No minimum or floor waiver is added.
    env.update(SHAPE_ALT_TOL=500,SHAPE_MIN_BURN_DV=.1)
    assert not env['shapeNextBurn'](goals) and not nodes
    spent=92.38606194
    saved['land_prep_budget']=prep.Lex(CONTEXT=env['landingOrbitContext'](),SPENT=spent,NODE_UT=-1,NODE_DV=0)
    prior={key:env[key] for key in ('SHAPE_ALT_TOL','SHAPE_MIN_BURN_DV','SHAPE_MIN_PE',
                                    'SHAPE_ANG_TOL','BURN_STAGE_LIMIT')}
    events.clear();prep.run(env)
    assert saved['phase']=='LANDING_REVIEW' and len(nodes)==1
    assert [event[1] for event in events if event[0]=='plan']==['set-ap']
    assert ship.PERIAPSIS==ship.APOAPSIS==15600 and ship.PERIAPSIS>=10000
    assert 50<nodes[0].DELTAV.MAG<70 and abs(nodes[0].DELTAV.MAG-expected_dv)<1e-9
    assert abs(saved['land_prep_budget']['SPENT']-spent-nodes[0].DELTAV.MAG)<1e-8
    assert ship.DELTAV.VACUUM>=900 and env['STAGE'].DELTAV.VACUUM>=10
    assert all(env[key]==value for key,value in prior.items())
    for name in ('minmus_lander','minmus_contract_lander_return'):
        mission=fleet.profile(name)
        assert mission['SHAPE_OPERATIONAL_TOLERANCE']==1 and mission['SHAPE_ALT_TOL']==1000
        assert mission['SHAPE_MIN_PE']==10000
        expected_capture,expected_shape=(650,300) if name=='minmus_lander' else (900,900)
        assert mission['CAPTURE_RESERVE_DV']==expected_capture and mission['SHAPE_RESERVE_DV']==expected_shape
    print('PASS: recorded rounded15.6x1050.8km capture now uses one useful Pe burn to15.6km circular, retains minimum/floor/stage/reserve/ledger, restores SHAPE policy and advances only to landing review')


def check_reachable_apsis_corridors():
    for body in ('Minmus','Mun'):
        for margin in (250,1000):
            for offset,expected in ((margin-.01,'set-ap'),(margin,'set-ap'),(margin+.01,'set-pe')):
                env,_,events,nodes,refresh=prep.fixture(False)
                ship=env['SHIP']
                if body=='Mun':ship.BODY.RADIUS=200000;ship.BODY.MU=6.5138398e10
                ship.PERIAPSIS=15000+offset;ship.APOAPSIS=1000000;refresh()
                env.update(SHAPE_ALT_TOL=margin,SHAPE_MIN_BURN_DV=.000001)
                goals=prep.Lex(AP=15000,PE=15000,INC=ship.ORBIT.INCLINATION,LAN=ship.ORBIT.LAN)
                nd=env['shapeNextBurn'](goals)
                assert nd['label']==expected and len(nodes)==1,(body,margin,offset)
                if expected=='set-ap':
                    assert nodes[0].ORBIT.APOAPSIS==nodes[0].ORBIT.PERIAPSIS==ship.PERIAPSIS
                    assert abs(nodes[0].ORBIT.APOAPSIS-15000)<=margin
                else:
                    assert nodes[0].ORBIT.PERIAPSIS==15000 and nodes[0].ORBIT.APOAPSIS==1000000
    print('PASS: generic tangent planner circularizes at reachable current Pe only inside the exact requested Ap corridor, including its boundary; outside it still changes Pe first on both moons')


def check_contract_isolation_and_safety():
    env,ship,events=accuracy_fixture();env.update(SHAPE_ALT_TOL=500,SHAPE_MIN_BURN_DV=.1)
    goals=ordering.Lex(AP=15000,PE=15000);seen=[]
    env['shapeTargets']=lambda:goals
    env['shapeOperationalAltitudeTolerance']=lambda *args:tolerance(env,*args)
    env['_runShapePhase']=lambda *args:seen.append((args,env['SHAPE_ALT_TOL']))
    ship.AVAILABLETHRUST=200*ship.MASS
    for operational,expected in ((0,500),(1,1500)):
        env['SHAPE_OPERATIONAL_TOLERANCE']=operational
        invoke(SOURCE,'phaseShape',env)
        assert seen[-1]==(('SHAPE','SHAPE_'),expected) and env['SHAPE_ALT_TOL']==500
    contract=fleet.profile('minmus_orbital_surveyor')
    assert contract.get('SHAPE_OPERATIONAL_TOLERANCE',0)==0 and contract['SHAPE_ALT_TOL']==500
    # A large allowed target error cannot turn below-floor/nonfinite Pe into
    # success, even if every requested orbit error is otherwise in tolerance.
    env,_,_=ordering.fixture();env.update(SHAPE_ALT_TOL=10000,_peFloor=lambda:10000,
                                         targets=goals,shapeErrors=lambda _:ordering.Lex(AP=0,PE=0))
    for pe,accepted in ((9999,False),(10000,True),(math.nan,False),(math.inf,False)):
        env['SHIP'].PERIAPSIS=pe
        assert ordering.execute('shapeConverged',env)==accepted
    env,ship,_=accuracy_fixture();good=tolerance(env,goals)
    for obj,field,bad in ((ship,'MASS',0),(ship,'AVAILABLETHRUST',math.nan),(ship.BODY,'MU',0)):
        prior=getattr(obj,field);setattr(obj,field,bad)
        assert tolerance(env,goals)==250;setattr(obj,field,prior)
    assert good>=250 and tolerance(env,ordering.Lex(),500)==500
    print('PASS: strict contract mode stays500m with a strong motor, opt-in operational scope restores settings, and below-floor/nonfinite orbits and invalid authority cannot gain acceptance')


if __name__=='__main__':
    check_authority_and_independent_sensitivity()
    check_reported_high_capture_transition()
    check_reachable_apsis_corridors()
    check_contract_isolation_and_safety()
