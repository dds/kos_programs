"""Stable/multiscale survey previews against Cartesian orbits and synthetic maps.

These fixtures prove search decisions, not scanner swaths or native coverage.
"""
import re

import check_survey_orbit as survey
import check_relay_constellation as harness
from check_espoir_fleet import Items,Text


def window(env):
    period=env['SHIP'].ORBIT.PERIOD
    start=env['TIME'].SECONDS+env['etaToTrueAnomaly'](-env['SHIP'].ORBIT.ARGUMENTOFPERIAPSIS)+2*period
    return start,6*period


def tracks(env,cell):
    start,span=window(env);lanes=[set(),set()]
    for j in range(384):lanes[j%2].add(cell(env['lmGroundGeoAt'](start+span*(j+.5)/384)))
    return lanes


def score(env,node,cache):
    details=harness.Record();start,span=window(env)
    value=env['surveyOrbitScore'](env['SHIP'],node,Text('HIRESALTIMETRY'),start,span,
        env['TIME'].SECONDS+45,env['KUNIVERSE'].REALTIME+60,details,cache)
    return value,details


def baseline_row(events):
    row=next(e for e in events if isinstance(e,str) and 'scanorbit baseline ' in e)
    return tuple(float(re.search(key+r'=([^ ]+)',row)[1]) for key in ('score','gridA','gridB','startUt'))


def check_repeat_preview_same_crossing():
    env,ship,state,events,nodes,world,cell=survey.fixture(inc=90,body='Kerbin')
    def completed(obj,geo):
        lat,lng=cell(geo)
        return Items([Text('HIRESALTIMETRY')]) if (lat*17+lng*11)%37<14 else Items()
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=completed
    clock=env['TIME'];clock.SECONDS+=100;env['ETA'].PERIAPSIS-=100;env['ETA'].APOAPSIS-=100
    first=survey.search(env);before=baseline_row(events)
    if first['OK']:env['fixture_remove'](first['NODE'])
    events.clear();clock.SECONDS+=40;env['ETA'].PERIAPSIS-=40;env['ETA'].APOAPSIS-=40
    second=survey.search(env);after=baseline_row(events)
    assert all(abs(a-b)<1e-7 for a,b in zip(before,after))
    assert first['OK']==second['OK'] and first['REASON']==second['REASON']
    if first['OK']:
        assert first['BEST']['MODE']==second['BEST']['MODE']
        assert abs(first['BEST']['SCORE']-second['BEST']['SCORE'])<1e-8
        assert abs(first['BEST']['PRO']-second['BEST']['PRO'])<1e-8
        env['fixture_remove'](second['NODE'])
    assert not env['HASNODE'] and state['shape_budget_spent']==10
    print('PASS: repeated Kerbin polar previews40s apart on the same unchanged38%-style patch map retain identical anchored epochs, paired baseline scores and decisions; no budget spent')


def check_one_grid_cannot_authorize_and_cell_cache():
    env,_,_,_,_,world,cell=survey.fixture(inc=90,body='Kerbin')
    baseline=tracks(env,cell)
    node=env['surveyOrbitDriftNode'](True,1250);candidate=tracks(env,cell)
    env['fixture_remove'](node)
    mapped=baseline[0]|baseline[1]|candidate[1]
    calls=[]
    def completed(obj,geo):
        calls.append(cell(geo))
        return Items([Text('HIRESALTIMETRY')]) if cell(geo) in mapped else Items()
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=completed
    cache=harness.Record();base,base_grids=score(env,0,cache)
    assert base==0
    node=env['surveyOrbitDriftNode'](True,1250)
    trial,trial_grids=score(env,node,cache)
    assert trial>0 and trial_grids['A']>.1 and trial_grids['B']==0
    assert not env['_surveyOrbitGain'](trial_grids,base_grids)
    before=len(calls)
    assert score(env,node,cache)==(trial,trial_grids) and len(calls)==before
    assert len(calls)==len(set(calls))==len(cache)
    env['fixture_remove'](node)
    print('PASS: a favorable first grid with no second-grid gain cannot authorize a maneuver; each canonical map cell is queried once across baseline/candidates/final resampling')


def check_smaller_detuning_finds_missed_corridor():
    env,ship,state,events,nodes,world,cell=survey.fixture(inc=90,body='Kerbin')
    baseline=tracks(env,cell);old_mapped=baseline[0]|baseline[1]
    for raised in (True,False):
        nd=env['surveyOrbitDriftNode'](raised,5000)
        lanes=tracks(env,cell);old_mapped|=lanes[0]|lanes[1]
        env['fixture_remove'](nd)
    nd=env['surveyOrbitDriftNode'](True,1250);small=tracks(env,cell);env['fixture_remove'](nd)
    missing=(small[0]|small[1])-old_mapped
    assert small[0]&missing and small[1]&missing
    def completed(obj,geo):
        return Items() if cell(geo) in missing else Items([Text('HIRESALTIMETRY')])
    env['ADDONS'].SCANSAT.COMPLETEDSCANS=completed
    out=survey.search(env)
    assert out['OK'] and out['BEST']['MODE'] in ('raise-ap','lower-pe')
    assert out['BEST']['SAMPLES']['A']>.1 and out['BEST']['SAMPLES']['B']>.1
    assert out['NODE'].DELTAV.MAG<2.5 and out['NODE'].ORBIT.PERIAPSIS>=90000-1e-6
    assert out['NODE'].ORBIT.APOAPSIS<=110000+1e-6 and state['shape_budget_spent']==10
    rows=[row for row in events if isinstance(row,str) and 'scanorbit candidate' in row]
    assert len(rows)==8 and any('stepM=1250' in row for row in rows)
    for row in rows:
        if 'stepM=5000' in row:assert float(re.search(r' score=([^ ]+)',row)[1])==0
    assert any('scanorbit confirmation' in row for row in events if isinstance(row,str))
    env['fixture_remove'](out['NODE'])
    print('PASS: synthetic gaps missed by both old5km trials are found by a cheaper~1m/s detuning; eight bounded drift candidates and final paired validation run without changing limits or budget')


def check_recreated_node_requires_confirmation():
    env,ship,state,_,nodes,world,cell=survey.fixture(inc=90,body='Kerbin')
    survey.record_current_track(env,world,cell)
    class ChangedPrediction(survey.Node):
        ORBIT=property(lambda self:ship.ORBIT)
    calls=[]
    def make_node(*args):
        calls.append(args)
        return (ChangedPrediction if len(calls)==9 else survey.Node)(env,*args)
    env['NODE']=make_node
    out=survey.search(env)
    assert len(calls)==9 and not out['OK'] and out['REASON']=='final-score-unconfirmed'
    assert not env['HASNODE'] and not any(nd.alive for nd in nodes)
    assert state['shape_budget_spent']==10
    print('PASS: changed native-style prediction on the recreated winner cannot retain an unsupported node or spend budget; final paired resampling removes only its own preview')


if __name__=='__main__':
    check_repeat_preview_same_crossing()
    check_one_grid_cannot_authorize_and_cell_cache()
    check_smaller_detuning_finds_missed_corridor()
    check_recreated_node_requires_confirmation()
