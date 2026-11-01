"""Nearby scan planes against independent Cartesian impulses and synthetic map gaps."""
import math
import re

import check_relay_constellation as harness
import check_survey_orbit as survey
import check_survey_sampling as sampling
from check_espoir_fleet import Items, Text, native


def gap_fixture(sign):
    env,ship,state,events,nodes,world,cell=survey.fixture(inc=90.000118,body='Kerbin')
    lanes=sampling.tracks(env,cell);mapped=lanes[0]|lanes[1]
    # All baseline/drift tracks and the other three tilted tracks are mapped.
    # Only cells reached by the preferred0.5deg tilt remain blank. Geometry
    # comes from independent Kepler propagation, not mocked score responses.
    for scale in (.25,.5,1,2):
        for raised in (True,False):
            step=5000*scale if raised else min(5000*scale,9999)
            node=env['surveyOrbitDriftNode'](raised,step)
            lanes=sampling.tracks(env,cell);mapped|=lanes[0]|lanes[1]
            env['fixture_remove'](node)
    preferred=None
    for offset in (-.5,.5,-1,1):
        node=env['planPlaneMatch'](ship.ORBIT.INCLINATION+offset,ship.ORBIT.LAN)
        lanes=sampling.tracks(env,cell)
        if offset==sign*.5:preferred=lanes
        else:mapped|=lanes[0]|lanes[1]
        env['fixture_remove'](node)
    assert all(len(lane-mapped)>50 for lane in preferred)
    world['coverage'].update(mapped)
    events.clear();nodes.clear()
    return env,ship,state,events,nodes


def check_kerbin_tilt(sign):
    env,ship,state,events,nodes=gap_fixture(sign)
    before=state.copy();original=ship.ORBIT
    out=survey.search(env,'tilt',50)
    assert out['OK'] and out['BEST']['MODE']=='tilt'
    node=out['NODE'];orb=node.ORBIT
    assert abs(orb.INCLINATION-original.INCLINATION-sign*.5)<1e-7
    assert abs(orb.LAN-original.LAN)<1e-7
    assert abs(orb.PERIAPSIS-original.PERIAPSIS)<1e-6 and abs(orb.APOAPSIS-original.APOAPSIS)<1e-6
    speed=math.sqrt(ship.BODY.MU/(ship.BODY.RADIUS+100000))
    expected=2*speed*math.sin(math.radians(.5)/2)
    assert abs(node.DELTAV.MAG-expected)<1e-8 and 19<node.DELTAV.MAG<20
    assert out['BEST']['SAMPLES']['A']>.1 and out['BEST']['SAMPLES']['B']>.1
    assert state==before and len(nodes)==5 and sum(nd.alive for nd in nodes)==1
    rows=[row for row in events if 'scanorbit candidate' in row]
    assert len(rows)==4 and all('mode=tilt' in row and 'targetInc=' in row for row in rows)
    actual={round(float(re.search(r' targetInc=([^ ]+)',row)[1])-original.INCLINATION,5) for row in rows}
    assert actual=={-.5,.5,-1,1}
    env['fixture_remove'](node)
    print('PASS: Kerbin'+str(sign*.5)+'deg tilt finds independently propagated gaps missed by drift/other planes, costs19.60m/s, preserves LAN/apsides and requires both grids; preview budget unchanged')


def check_tilt_command(action):
    env,_,state,events,nodes=gap_fixture(-1)
    before=state.copy()
    env.update(action=Text(action),mode=Text('tilt'),cap=native(50))
    harness.invoke(survey.COMMAND,'_cmdScanorbit',env)
    assert env['HASNODE']==(action=='plan')
    assert any('schema=3' in row and 'mode=tilt' in row for row in events)
    assert any('scanorbit selected mode=tilt' in row for row in events)
    assert all(state[key]==value for key,value in before.items() if key!='shape_budget_spent')
    if action=='plan':
        assert abs(state['shape_budget_spent']-before['shape_budget_spent']-env['NEXTNODE'].DELTAV.MAG)<1e-8
    else:assert state==before and not any(nd.alive for nd in nodes)
    print('PASS: actual tilt '+action+' command accepts its new mode, archives intended/actual inclination and charges only an explicitly retained native node')


def check_plane_deduplication_and_budget():
    env,_,_,_,_,_,_=survey.fixture(inc=89.5)
    for mode in ('auto','tilt','polar','mirror'):
        trials=Items()
        for kind,want in (('polar',90),('mirror',90.5),('tilt',89),('tilt',90),('tilt',88.5),('tilt',90.5)):
            env['_surveyOrbitAddPlane'](trials,Text(kind),want,Text(mode))
        wants=[trial['INC'] for trial in trials]
        assert len(wants)==len(set(wants))
        expected={'auto':{90,90.5,89,88.5},'tilt':{89,90,88.5,90.5},'polar':{90},'mirror':{90.5}}
        assert set(wants)==expected[mode]
        env['_surveyOrbitAddPlane'](trials,Text('tilt'),74.9,Text(mode))
        env['_surveyOrbitAddPlane'](trials,Text('tilt'),105.1,Text(mode))
        assert [trial['INC'] for trial in trials]==wants
    for fault in ('cap','mission-cap','cumulative','reserve','stage'):
        env,_,state,events,nodes,_,_=survey.fixture(inc=90,body='Kerbin')
        cap=50
        if fault=='cap':cap=10
        if fault=='mission-cap':env['SHAPE_DV_CAP']=10
        if fault=='cumulative':state['shape_budget_spent']=490
        if fault=='reserve':env['SHAPE_RESERVE_DV']=990
        if fault=='stage':env['STAGE'].DELTAV.VACUUM=20
        def forbidden(*_):raise AssertionError('plane solver ran for an unaffordable lower bound')
        env['planPlaneMatch']=forbidden
        out=survey.search(env,'tilt',cap)
        assert not out['OK'] and not env['HASNODE'] and not nodes
        rows=[row for row in events if 'scanorbit skipped mode=tilt' in row]
        assert len(rows)==4 and all('lower-bound-outside-budget-or-minimum' in row for row in rows)
    print('PASS: each mode retains its unique requested planes,75..105deg bounds remain; cap/mission/cumulative/reserve/active-stage lower bounds skip costly native solvers without weakening final admission')


def check_final_plane_and_deadline():
    env,_,state,_,nodes=gap_fixture(-1)
    env['NODE']=lambda ut,ra,no,pr:survey.Node(env,ut,ra,no*1.8,pr)
    out=survey.search(env,'tilt',50)
    assert not out['OK'] and out['REASON']=='final-validation'
    assert not env['HASNODE'] and not any(nd.alive for nd in nodes) and state['shape_budget_spent']==10
    env,_,_,_,nodes,_,_=survey.fixture(inc=90,body='Kerbin')
    plane=env['planPlaneMatch']
    def late(*args):
        node=plane(*args);env['TIME'].SECONDS+=46;return node
    env['planPlaneMatch']=late
    out=survey.search(env,'tilt',50)
    assert not out['OK'] and not env['HASNODE'] and not any(nd.alive for nd in nodes)
    assert out['REASON']=='sampling-deadline'
    print('PASS: a recreated winner outside its intended plane cannot pass via other favorable map samples; over-deadline native plane planning removes its owned preview and retains no maneuver')


def check_cached_ephemerides_preserve_equations():
    # Retain the previous vector form as a separate oracle. Every dynamical
    # input belongs in the cache key; no time rounding or fewer Newton steps.
    def previous(mu,a,e,mean,epoch,peri,across,ut):
        n=2*math.pi/(2*math.pi*math.sqrt(a**3/mu))
        mean=(mean+n*(ut-epoch)+math.pi)%(2*math.pi)-math.pi;ea=mean
        for _ in range(8):ea-=(ea-e*math.sin(ea)-mean)/(1-e*math.cos(ea))
        pos=survey.add(survey.mul(peri,a*(math.cos(ea)-e)),survey.mul(across,a*math.sqrt(1-e*e)*math.sin(ea)))
        vel=survey.mul(survey.add(survey.mul(peri,-math.sin(ea)),survey.mul(across,math.sqrt(1-e*e)*math.cos(ea))),n*a/(1-e*math.cos(ea)))
        return pos,vel
    survey.propagate.cache_clear()
    base=(3.5316e12,700000,.01,.4,1000,(1,0,0),(0,.2,math.sqrt(.96)),1234.56789)
    cases=[base]
    for index,value in enumerate((6.5138398e10,800000,.8,.5,1100,(0,1,0),(.2,0,math.sqrt(.96)),1234.567890001)):
        args=list(base);args[index]=value;cases.append(tuple(args))
    for args in cases:
        expected=previous(*args);actual=survey.propagate(*args)
        assert actual==expected and survey.propagate(*args)==actual
    info=survey.propagate.cache_info()
    assert info.misses==len(cases) and info.hits==len(cases)
    print('PASS: cached fixture ephemerides exactly match the original eight-step/vector equations; changing any conic/frame/epoch/time input causes a fresh calculation without rounded epochs')


if __name__=='__main__':
    check_kerbin_tilt(-1)
    check_kerbin_tilt(1)
    check_tilt_command('preview')
    check_tilt_command('plan')
    check_plane_deduplication_and_budget()
    check_final_plane_and_deadline()
    check_cached_ephemerides_preserve_equations()
