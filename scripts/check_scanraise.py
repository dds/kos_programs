"""Explicit mapper drift plan: real command/guards/ledger and independent conics."""
import math
from types import SimpleNamespace as NS

import check_survey_orbit as survey
import check_relay_constellation as harness
from check_codebase import ROOT, function_body, command_entrypoint_errors
from check_espoir_fleet import Text, native, profile

SOURCE=(ROOT/'cmd/scanraise.ks').read_text()
NESTED='LOCAL FUNCTION validNode {'+function_body(SOURCE,'validNode')+'}'
NAMES=('craftRef','bodyRef','phase_','launch_','vehicle','mid','pe','inc','lan','targetAlt','nd','cap','reserve')
COMMAND=SOURCE.replace(NESTED,'fixtureBind('+','.join(NAMES)+').')
COMMAND=COMMAND.replace('IF DEFINED EXCURSION_RESERVE_DV','IF fixtureDefined()')
assert COMMAND!=SOURCE and NESTED not in COMMAND


def fixture():
    env,ship,state,events,nodes,world,_=survey.fixture(inc=90,body='Kerbin')
    env.update(profile('kerbin_orbital_surveyor'),apoapsisKm=native(130),cap=native(50))
    state['mission_id']=Text('kerbin_orbital_surveyor')
    # Independent Cartesian version of the measured99.204x100.725km orbit.
    rp=ship.BODY.RADIUS+99203.6554;ra=ship.BODY.RADIUS+100725.0243
    inc=math.radians(90.0001558);lan=math.radians(40)
    speed=math.sqrt(ship.BODY.MU*(2/rp-2/(rp+ra)))
    ship.ORBIT=survey.Orbit(ship.BODY,(rp*math.cos(lan),rp*math.sin(lan),0),
        (-speed*math.sin(lan)*math.cos(inc),speed*math.cos(lan)*math.cos(inc),speed*math.sin(inc)),1500)
    binding={}
    env.update(bootApplyMissionConfig=lambda *_:True,
        fixtureBind=lambda *args:binding.update(zip(NAMES,args)))
    env['validNode']=lambda:survey.source_call(SOURCE,'validNode',dict(env,**binding))
    return env,ship,state,events,nodes,world


def run(env):harness.invoke(COMMAND,'_cmdScanraise',env)


def check_measured_mapper_raise():
    env,ship,state,events,nodes,_=fixture();before=state.copy();orb=ship.ORBIT
    def forbidden(*_):raise AssertionError('explicit plan invoked coverage search or automatic flight')
    env.update(surveyOrbitSearch=forbidden,executeManeuver=forbidden)
    run(env)
    assert env['HASNODE'] and len(nodes)==1 and nodes[0].alive
    nd=env['NEXTNODE'];new=nd.ORBIT
    assert abs(new.PERIAPSIS-orb.PERIAPSIS)<1e-6 and abs(new.APOAPSIS-130000)<1e-6
    assert abs(new.INCLINATION-orb.INCLINATION)<1e-7 and abs(new.LAN-orb.LAN)<1e-7
    assert 22<nd.DELTAV.MAG<24 and nd.ETA>=180
    period_delta=new.PERIOD-orb.PERIOD
    assert 1<360*period_delta/ship.BODY.ROTATIONPERIOD<1.1
    assert new.ECCENTRICITY<.1 and new.PERIAPSIS>=80000 and new.APOAPSIS<250000
    assert all(state[key]==value for key,value in before.items() if key!='shape_budget_spent')
    assert abs(state['shape_budget_spent']-before['shape_budget_spent']-nd.DELTAV.MAG)<1e-7
    assert env['SHAPE_AP']==130000 and env['SHAPE_PE']==100000 # Profile goals unchanged.
    assert any('coverageGain=operator-experiment' in row for row in events)
    assert not command_entrypoint_errors(SOURCE)
    assert 'VELOCITYAT' not in SOURCE and 'executeManeuver' not in SOURCE
    print('PASS: measured mapper plans one22.86m/s burn to99.204x130km, preserves polar plane/Pe/profile/phase, changes groundtrack spacing~1deg/orbit and reserves only its actual cost')


def check_scanraise_guards():
    changes={
        'no-link':lambda e,s,st,w:setattr(e['HOMECONNECTION'],'ISCONNECTED',False),
        'bad-alt-type':lambda e,s,st,w:e.update(apoapsisKm=Text('130')),
        'nan-alt':lambda e,s,st,w:e.update(apoapsisKm=native(math.nan)),
        'not-raised':lambda e,s,st,w:e.update(apoapsisKm=native(100)),
        'eccentric':lambda e,s,st,w:e.update(apoapsisKm=native(300)),
        'outside-soi':lambda e,s,st,w:e.update(apoapsisKm=native(90000)),
        'cap-type':lambda e,s,st,w:e.update(cap=Text('50')),
        'nan-cap':lambda e,s,st,w:e.update(cap=native(math.nan)),
        'cap':lambda e,s,st,w:e.update(cap=native(20)),
        'mission-cap':lambda e,s,st,w:e.update(SHAPE_DV_CAP=20),
        'cumulative':lambda e,s,st,w:st.update(shape_budget_spent=240),
        'reserve':lambda e,s,st,w:e.update(SHAPE_RESERVE_DV=990),
        'stage':lambda e,s,st,w:setattr(e['STAGE'].DELTAV,'VACUUM',23),
        'abort':lambda e,s,st,w:e.update(ABORT=True),
        'warp':lambda e,s,st,w:e.update(WARP=1),
        'node':lambda e,s,st,w:e.update(HASNODE=True,NEXTNODE=NS()),
        'pending':lambda e,s,st,w:st.update(burn_pending=Text('true')),
        'started':lambda e,s,st,w:st.update(burn_started=Text('true')),
        'route':lambda e,s,st,w:st.update(hop_route_active=True),
        'phase':lambda e,s,st,w:st.update(phase=Text('MCC')),
        'active':lambda e,s,st,w:setattr(e['KUNIVERSE'],'ACTIVEVESSEL',NS()),
        'thrust':lambda e,s,st,w:setattr(s,'THRUST',1),
        'raw':lambda e,s,st,w:setattr(s.CONTROL,'MAINTHROTTLE',.1),
        'pilot':lambda e,s,st,w:setattr(s.CONTROL,'PILOTMAINTHROTTLE',.1),
        'floor':lambda e,s,st,w:e.update(SHAPE_MIN_PE=100000),
        'scanner':lambda e,s,st,w:s.PARTS.clear(),
        'profile':lambda e,s,st,w:e.update(bootApplyMissionConfig=lambda *_:False),
    }
    for fault,change in changes.items():
        env,ship,state,_,nodes,world=fixture();change(env,ship,state,world);before=state.copy()
        run(env)
        assert state==before and not any(nd.alive for nd in nodes),fault
        if fault=='node':assert env['HASNODE'] and not nodes
        else:assert not env['HASNODE'],fault
    print(f'PASS: {len(changes)} invalid/unsafe/fuel/mission/control/scanner contexts preserve mission state and foreign nodes; an explicit request never waives physical or budget admission')


def check_native_rejection_and_final_recheck():
    for fault in ('ap','pe','inclination','lan','patch','context','foreign'):
        env,ship,state,events,nodes,_=fixture();before=state.copy()
        if fault in ('ap','pe','inclination','lan','patch'):
            class Wrong(survey.Node):
                @property
                def ORBIT(self):
                    orb=super().ORBIT
                    if fault=='ap':orb.SEMIMAJORAXIS+=10000
                    if fault=='pe':orb.ECCENTRICITY=.08
                    if fault=='inclination':orb.INCLINATION=89
                    if fault=='lan':orb.LAN=42
                    if fault=='patch':orb.HASNEXTPATCH=True
                    return orb
            env['NODE']=lambda *args:Wrong(env,*args)
        else:
            def changed(*_):
                if fault=='context':state['mission_id']=Text('other')
                else:
                    foreign=NS();env['ALLNODES'].append(foreign);events.append('foreign')
                return True
            env['diagnosticArchiveClose']=changed
        run(env)
        if fault=='context':before['mission_id']=Text('other')
        assert state==before,fault
        if fault=='foreign':assert env['HASNODE'] and len(env['ALLNODES'])==2 and nodes[0].alive
        else:assert not env['HASNODE'] and not any(nd.alive for nd in nodes),fault
    print('PASS: wrong native apsides/plane/SOI patch reject; archive-time mission or foreign-node changes prevent reservation without deleting unrelated maneuvers')


if __name__=='__main__':
    check_measured_mapper_raise()
    check_scanraise_guards()
    check_native_rejection_and_final_recheck()
