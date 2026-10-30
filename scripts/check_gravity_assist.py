"""Ordered native itinerary/refinement fixtures, not KSP gravity propagation."""
import math
import re
from types import SimpleNamespace as NS
from functools import lru_cache
import check_landing_guidance as ks
from check_codebase import ROOT,function_body,dependency_tables,closure,command_entrypoint_errors
from check_minmus_kolniya import execute, executable
from check_espoir_fleet import Map,Items
from arrival_fixture import EventEta

SOURCE=(ROOT/'lib/gravity_assist.ks').read_text()


@lru_cache(None)
def prepared(name):
    code=function_body(SOURCE,name)
    params=re.findall(r'PARAMETER (\w+)',code)
    code=code.replace('LIST BODIES IN bodies.','fixture_bodies(bodies).')
    code=code.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED OR ABORT.','fixture_settled().')
    code=code.replace('REMOVE nd.','fixture_remove(nd).')
    return params,ks.compile_nodes(ks.freeze(executable(code)))


def call(name,env,*args):
    params,compiled=prepared(name)
    local=env if name=='planAssistRefinement' else dict(env)
    local.update(zip(params,args))
    try:ks.execute(compiled,local)
    except ks.Returned as result:return result.value


def fixture():
    clock=NS(SECONDS=1000)
    sun=NS(NAME='Sun',HASBODY=False,ATM=NS(EXISTS=False),RADIUS=260000000,SOIRADIUS=1e20)
    duna=NS(NAME='Duna',HASBODY=True,BODY=sun,ATM=NS(EXISTS=True,HEIGHT=50000),RADIUS=320000,SOIRADIUS=47921949,MU=3.0136321e11)
    ike=NS(NAME='Ike',HASBODY=True,BODY=duna,ATM=NS(EXISTS=False),RADIUS=130000,SOIRADIUS=1049598,MU=1.8568369e10)
    route=Items([Map(BODY='Ike',MIN_PE=25000),Map(BODY='Duna',MIN_PE=75000,AP=2880000)])
    def patch(body,pe,pe_epoch,ecc,next_patch=None,exit_epoch=0):
        return NS(BODY=body,PERIAPSIS=pe,ECCENTRICITY=ecc,INCLINATION=0,
                  ETA=EventEta(clock,pe_epoch),HASNEXTPATCH=next_patch is not None,
                  NEXTPATCH=next_patch,NEXTPATCHETA=exit_epoch-clock.SECONDS)
    nodes=Items();events=[]
    final=patch(duna,100000,16000,1.5)
    moon=patch(ike,30000,13000,2,final,14000)
    transit=patch(duna,85000,15000,2,moon,12000)
    initial=patch(sun,1e10,9000,.1,transit,10000)
    class Node:
        def __init__(self,t,rad,norm,pro):self.TIME=t;self.RADIALOUT=rad;self.NORMAL=norm;self.PROGRADE=pro
        @property
        def ORBIT(self):return initial
        @property
        def DELTAV(self):return NS(MAG=math.sqrt(self.RADIALOUT**2+self.NORMAL**2+self.PROGRADE**2))
    env=dict(TIME=clock,ABORT=False,HASNODE=False,ALLNODES=nodes,NEXTNODE=None,WARP=0,
        SHIP=NS(STATUS='ORBITING',THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
                DELTAV=NS(VACUUM=2000),ORBIT=NS(HASNEXTPATCH=True,NEXTPATCHETA=9000)),
        LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])),SQRT=math.sqrt,
        NODE=Node,ASSIST_MAX_TRIALS=48,ASSIST_PLAN_SECONDS=30,ASSIST_MIN_GAIN=25,ASSIST_DV_CAP=50,ASSIST_RESERVE_DV=100,
        fixture_bodies=lambda rows:rows.extend([sun,duna,ike]),
        fixture_settled=lambda:None,maneuverBurnInterrupted=lambda:False,arrivalBurnSeconds=lambda _:10,
        arrivalPatchPeUt=lambda p,start:(clock.SECONDS+p.ETA.PERIAPSIS
            if clock.SECONDS+p.ETA.PERIAPSIS>start and (not p.HASNEXTPATCH or p.ETA.PERIAPSIS<p.NEXTPATCHETA) else -1))
    def add(nd):nodes.append(nd);env.update(HASNODE=True,NEXTNODE=nd)
    def remove(nd):nodes.remove(nd);env.update(HASNODE=bool(nodes),NEXTNODE=nodes[0] if nodes else None)
    def wait(dt):
        clock.SECONDS+=dt
        # Synthetic native-patch response isolates search/control logic.
        if nodes:final.ECCENTRICITY=max(.1,1.5-.04*nodes[0].PROGRADE)
    env.update(fixture_add=add,fixture_remove=remove,fixture_wait=wait)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:call(name,env,*args)
    return env,route,[sun,duna,ike],[initial,transit,moon,final],nodes,events


def check_native_itinerary():
    env,route,bodies,patches,_,_=fixture()
    nd=env['NODE'](1600,0,0,0)
    resolved=env['assistRouteBodies'](route)
    assert resolved==[bodies[2],bodies[1]]
    result=env['assistEvaluate'](nd,route,resolved)
    assert result['OK'] and len(result['LEGS'])==2
    expected=abs(math.sqrt(bodies[1].MU*2.5/420000)-math.sqrt(bodies[1].MU*(2/420000-2/(420000+320000+2880000))))
    assert abs(result['COST']-expected)<1e-8
    for fault in ('clearance','truncated','bound','missing','parent','plane','nan','wrong-body','ap'):
        env,r,bs,ps,_,_=fixture();nd=env['NODE'](1600,0,0,0)
        if fault=='clearance':ps[2].PERIAPSIS=1000
        if fault=='truncated':ps[2].ETA=EventEta(env['TIME'],15000)
        if fault=='bound':ps[2].ECCENTRICITY=.8
        if fault=='missing':ps[2].HASNEXTPATCH=False
        if fault=='parent':ps[1].PERIAPSIS=40000
        if fault=='plane':r[1]['INC']=90
        if fault=='nan':ps[3].ECCENTRICITY=float('nan')
        if fault=='wrong-body':ps[2].BODY=NS(HASBODY=False)
        if fault=='ap':r[1]['AP']=80000
        assert not env['assistEvaluate'](nd,r,[bs[2],bs[1]])['OK'],fault
    # Repeated moon/parent legs are ordered by position, not phase-name lookup.
    env,r,bs,ps,_,_=fixture()
    r.insert(1,Map(BODY='Ike',MIN_PE=25000))
    second=NS(**vars(ps[2]));second.ETA=EventEta(env['TIME'],15000);second.NEXTPATCHETA=14500
    parent=NS(**vars(ps[1]));parent.NEXTPATCH=second;parent.NEXTPATCHETA=13500
    ps[2].NEXTPATCH=parent
    result=env['assistEvaluate'](env['NODE'](1600,0,0,0),r,[bs[2],bs[2],bs[1]])
    assert result['OK'] and [x['BODY'] for x in result['LEGS']]==['Ike','Ike','Duna']
    print('PASS: actual ordered native patches, safe in-patch flybys and final capture cost; truncated/unsafe/bound/unlisted/plane-invalid paths reject, repeated moon legs work')


def check_refinement_and_ownership():
    for fault in ('','node','interrupted','abort','fuel','no-seed','no-gain','removed','pilot','deadline','empty-route','unknown-body','bad-mu'):
        env,route,_,patches,nodes,_=fixture()
        if fault=='node':env['fixture_add'](env['NODE'](1500,0,0,0))
        if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if fault=='abort':env['ABORT']=True
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=50
        if fault=='no-seed':patches[2].HASNEXTPATCH=False
        if fault=='empty-route':route.clear()
        if fault=='unknown-body':route[0]['BODY']='missing'
        if fault=='bad-mu':patches[2].BODY.MU=0
        if fault=='no-gain':env['fixture_wait']=lambda dt:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+dt)
        if fault in ('removed','pilot','deadline'):
            original=env['fixture_wait'];count=[0]
            def wait(dt):
                original(dt);count[0]+=1
                if count[0]==2:
                    if fault=='removed':
                        nodes.clear();env.update(HASNODE=False,NEXTNODE=None)
                    if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.2
                    if fault=='deadline':env['TIME'].SECONDS+=1000
            env['fixture_wait']=wait
        result=env['planAssistRefinement'](route)
        if not fault:
            assert result['OK'] and len(nodes)==1
            assert result['TRIALS']<=48 and result['NODE'].DELTAV.MAG<=50
            assert result['COST']+25<=result['BASELINE_COST']
        else:
            assert not result['OK'],fault
            assert len(nodes)==(1 if fault=='node' else 0),fault
    print('PASS: bounded native refinement earns net savings with fuel reserve; failed/no-seed/unchanged/late/aborted cases clean only owned probes, foreign node and pilot input are preserved')


def check_capture_recovery_and_separation():
    src=(ROOT/'lib/capture.ks').read_text()
    for fault in ('node','interrupted','fuel','nan-fuel','infinite-fuel','infinite-node','execution',
                  'wait-node','wait-abort','wait-soi','wait-thrust','wait-raw','wait-pilot'):
        target=NS(NAME='Duna',SOIRADIUS=47921949)
        node=NS(DELTAV=NS(MAG=100))
        events=[]
        env=dict(SHIP=NS(BODY=target,PERIAPSIS=85000,APOAPSIS=1e8,DELTAV=NS(VACUUM=500),ORBIT=NS(ECCENTRICITY=1.5),
                        THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
            HASNODE=fault=='node',ABORT=False,maneuverBurnInterrupted=lambda:fault=='interrupted',
            missionTargetBody=lambda:target,midcourseClearReviewAlarm=lambda:None,
            yieldToPrompt=lambda:events.append('held'),fixture_wait=lambda _:None,
            CAPTURE_ACCEPT_BOUND=0,CAPTURE_MIN_PE=75000,CAPTURE_MAX_PE=95000,CAPTURE_RESERVE_DV=100,
            TARGET_AP=2880000,planCapture=lambda *_:events.append('plan') or node,
            fixture_remove=lambda _:events.append('remove'))
        if fault=='fuel':node.DELTAV.MAG=600
        if fault=='nan-fuel':env['SHIP'].DELTAV.VACUUM=float('nan')
        if fault=='infinite-fuel':env['SHIP'].DELTAV.VACUUM=float('inf')
        if fault=='infinite-node':node.DELTAV.MAG=float('inf')
        if fault.startswith('wait-'):
            def wait(_):
                if fault=='wait-node':env['HASNODE']=True
                if fault=='wait-abort':env['ABORT']=True
                if fault=='wait-soi':env['SHIP'].BODY=NS(NAME='Ike')
                if fault=='wait-thrust':env['SHIP'].THRUST=.2
                if fault=='wait-raw':env['SHIP'].CONTROL.MAINTHROTTLE=.2
                if fault=='wait-pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.2
            env['fixture_wait']=wait
        if fault=='execution':
            def burn():env['HASNODE']=True;events.append('burn');return False
            env['executeManeuver']=burn
        code=function_body(src,'phaseCapture').replace('REMOVE nd.','fixture_remove(nd).')
        execute(code,env)
        assert events[-1]=='held'
        if fault in ('node','interrupted') or fault.startswith('wait-'):assert events==['held']
        if fault in ('fuel','nan-fuel','infinite-fuel','infinite-node'):assert events==['plan','remove','held']
        if fault=='execution':assert events==['plan','burn','held']
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    ike=closure(phases['ike_setup'],deps);duna=closure(phases['duna_aerocapture'],deps)
    assert 'duna_entry' not in ike and 'maneuver' not in ike and 'ike_setup' not in duna
    assert 'gravity_assist' not in closure(phases['xing']+phases['capture'],deps)
    assert not command_entrypoint_errors((ROOT/'cmd/assistcheck.ks').read_text())
    print('PASS: capture preserves existing/interrupted maneuvers and fuel limits; Ike setup, Duna atmosphere and optional assist planning have separate library closures')


if __name__=='__main__':
    check_native_itinerary()
    check_refinement_and_ownership()
    check_capture_recovery_and_separation()
