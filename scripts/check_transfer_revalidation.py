"""Saved unflown departure drift: real corrector and phase, synthetic Pe response."""
import math
import re
from types import SimpleNamespace as NS

import check_departure_pe as departure
import check_relay_constellation as harness
from check_codebase import ROOT,function_body
from check_espoir_fleet import Text,Items,native

SOURCE=departure.SOURCE
CONTROL=(ROOT/'lib/xfer_plan.ks').read_text()
harness.SHARED.add('TRANSFER_PE_REFINE_DV_CAP')


def fixture(response=None):
    if response is None:response=lambda nd:12448+200000*(nd.PROGRADE-917.4214)
    env,nd,target=departure.fixture(response,first='Minmus')
    target.NAME=Text('Minmus');target.RADIUS=60000
    primary=target.BODY
    nd.TIME=269;nd.PROGRADE=917.4214
    ship=env['SHIP'];ship.BODY=primary;ship.STATUS=Text('ORBITING');ship.THRUST=0
    ship.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0);ship.ORBIT=NS(ECCENTRICITY=0,HASNEXTPATCH=False)
    saved=dict(phase=Text('XING'),mission_id=Text('minmus_lander'),launch_time=0,
        burn_pending=Text('true'),burn_started=Text('false'),burn_phase=Text('XING'),
        burn_body=Text('Kerbin'),burn_node_time=nd.TIME,burn_dv=nd.DELTAV.MAG)
    events=[]
    env.update(SHIP=ship,KUNIVERSE=NS(ACTIVEVESSEL=ship),HASNODE=True,NEXTNODE=nd,ALLNODES=Items([nd]),
        ABORT=False,WARP=0,phaseShouldYield=False,BURN_RESUME_REQUESTED=False,CAPTURE_PE=15000,
        LIST=lambda *xs:Items(xs),stateGet=lambda k,d='':saved.get(str(k),d),stateGetNum=lambda k,d=0:saved.get(str(k),d),
        MIN=min,MAX=max,ABS=abs,SQRT=math.sqrt,ROUND=round,
        _nodeAxisGet=lambda obj,axis:getattr(obj,str(axis)),
        _nodeAxisSet=lambda obj,axis,value:setattr(obj,str(axis),value),
        fixture_text=Text,_firstPatchBodyName=lambda _:target.NAME,
        missionTargetBody=lambda:target,orbitSummary=lambda:None,
        maneuverBurnInterrupted=lambda:saved['burn_started']=='true',maneuverDepartureFlown=lambda:False,
        _advanceTransfer=lambda _:events.append('advance'),
        _recordXingArrivalUt=lambda _:events.append('record'),
        yieldToPrompt=lambda:events.append('hold'))
    env['fixture_wait']=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt)
    for name in ('transferCorrectionFollows','transferImpactTargetEnabled','transferDepartureAim',
                 'transferDepartureReady','_departurePeCanProbe','_refineLocalDeparturePe','transferRevalidateUnflown'):
        env[name]=lambda *args,name=name:harness.invoke(SOURCE,name,env,*args)
    return env,nd,target,saved,events


def vector(nd):return nd.TIME,nd.PROGRADE,nd.RADIALOUT,nd.NORMAL


def check_reported_boundary_drift():
    env,nd,target,saved,_=fixture();original=vector(nd);before=saved.copy()
    assert not env['transferDepartureReady'](nd,target,15000,False)
    assert env['transferRevalidateUnflown'](nd,target,15000)
    assert env['transferDepartureReady'](nd,target,15000,False)
    assert abs(nd.PROGRADE-original[1]-.01276)<1e-7 and vector(nd)[0]==original[0]
    assert saved==before and env['TRANSFER_PE_REFINE_DV_CAP']==100
    assert env['TIME'].SECONDS<20
    print('PASS: reported Minmus12.448km versus15+/-2km saved node is restored into its original corridor by0.01276m/s vector polish, same epoch/ownership, under20s; original100m/s planner cap restored')


def check_failed_probe_restores_and_guards():
    for fault in ('flat','cap','late','abort','warp','active','foreign','started','phase','body','mission','pilot','wrong-first','missing'):
        response=(lambda nd:12448) if fault=='flat' else (lambda nd:12448+10*(nd.PROGRADE-917.4214)) if fault=='cap' else None
        env,nd,target,saved,_=fixture(response);original=vector(nd)
        if fault=='late':env['TIME'].SECONDS=100
        if fault=='abort':env['ABORT']=True
        if fault=='warp':env['WARP']=2
        if fault=='active':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='foreign':saved['burn_node_time']=1
        if fault=='started':saved['burn_started']=Text('true')
        if fault=='phase':saved['burn_phase']=Text('PARK')
        if fault=='body':saved['burn_body']=Text('Mun')
        if fault=='mission':saved['burn_mission_id']=Text('other')
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='wrong-first':env['_firstPatchBodyName']=lambda _:Text('Mun')
        if fault=='missing':env['_getTargetPatch']=lambda *_:0
        before=saved.copy()
        assert not env['transferRevalidateUnflown'](nd,target,15000),fault
        assert vector(nd)==original and saved==before and env['HASNODE'],fault
        assert env['TRANSFER_PE_REFINE_DV_CAP']==100
    for fault in ('abort','pilot','raw','thrust','started','phase','foreign'):
        env,nd,target,saved,_=fixture();original=vector(nd)
        def change_during_probe(dt):
            env['TIME'].SECONDS+=dt
            if fault=='abort':env['ABORT']=True
            if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
            if fault=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
            if fault=='thrust':env['SHIP'].THRUST=.1
            if fault=='started':saved['burn_started']=Text('true')
            if fault=='phase':saved['phase']=Text('BPLANE')
            if fault=='foreign':env['NEXTNODE']=NS(PROGRADE=123,TIME=42)
        env['fixture_wait']=change_during_probe
        assert not env['transferRevalidateUnflown'](nd,target,15000),fault
        if fault=='foreign':
            assert env['NEXTNODE'].PROGRADE==123 and env['NEXTNODE'].TIME==42
        else:assert vector(nd)==original,fault
    print('PASS: flat/over-cap/late/unsafe/unowned/interrupted/wrong-body/missing-patch cases preserve the exact original node and mission; Abort/control/phase changes during probing restore its vector, and a foreign node is untouched')


def check_real_saved_node_phase():
    env,nd,target,saved,events=fixture()
    def burn():
        assert env['transferDepartureReady'](nd,target,15000,False)
        events.append('burn');return True
    env['executeManeuver']=burn
    harness.invoke(CONTROL,'phaseTransfer',env)
    assert events==['burn','record','advance'] and saved['burn_started']=='false'
    print('PASS: real XING saved-node phase polishes before exactly one executor call and preserves normal phase handoff; no full departure replanning or tolerance widening')


if __name__=='__main__':
    check_reported_boundary_drift()
    check_failed_probe_restores_and_guards()
    check_real_saved_node_phase()
