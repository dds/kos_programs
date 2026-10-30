"""Manual assist-search: synthetic responses, NOT KSP propagation."""
import ast
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS
import check_landing_guidance as ks
import check_gravity_assist as old
from check_codebase import ROOT,function_body,mask,unscoped_returns,negated_defined_conditions
from check_espoir_fleet import Map,Items
from check_minmus_kolniya import executable
from check_deorbit_geometry import Vec
from arrival_fixture import EventEta

SEARCH='\n'.join((ROOT/f'lib/{name}.ks').read_text() for name in ('assist_search','assist_search_native'))
SOURCE=old.SOURCE+'\n'+SEARCH


@lru_cache(None)
def prepared(name):
    code=function_body(SOURCE,name)
    params=re.findall(r'PARAMETER (\w+)',code)
    defaults={key:ast.literal_eval(value) for key,value in re.findall(r'PARAMETER (\w+) IS ("[^"\n]*"|[0-9]+)\.',code)}
    code=code.replace('LIST BODIES IN bodies.','fixture_bodies(bodies).')
    code=code.replace('assistSearchNativeProbe@','NATIVE_PROBE')
    return params,defaults,ks.compile_nodes(ks.freeze(executable(code)))


def call(name,env,*args):
    params,defaults,code=prepared(name)
    local=dict(env);local.update(defaults);local.update(zip(params,args))
    try:ks.execute(code,local)
    except ks.Returned as result:return result.value


def fixture(entry=False,departure=False):
    clock=NS(SECONDS=1000)
    sun=NS(NAME='Sun',HASBODY=False,ATM=NS(EXISTS=False),RADIUS=260000000,SOIRADIUS=1e20,MU=1e18)
    duna=NS(NAME='Duna',HASBODY=True,BODY=sun,ATM=NS(EXISTS=True,HEIGHT=50000),RADIUS=320000,SOIRADIUS=47921949,MU=3.0136321e11)
    ike=NS(NAME='Ike',HASBODY=True,BODY=duna,ATM=NS(EXISTS=False),RADIUS=130000,SOIRADIUS=1049598,MU=1.8568369e10)
    kerbin=NS(NAME='Kerbin',HASBODY=True,BODY=sun,ATM=NS(EXISTS=True,HEIGHT=70000),RADIUS=600000,SOIRADIUS=84159286,MU=3.5316e12)
    body=kerbin if departure else sun
    goal=Map(BODY='Duna',MIN_PE=2000 if entry else 295000,MAX_PE=8000 if entry else 300000)
    if entry:goal['MODE']='ENTRY'
    else:goal['AP']=300000
    route=Items([Map(BODY='Ike',MIN_PE=25000),goal])
    state=dict(phase='XING' if departure else 'REFINE_BPLANE',mission_id='preview',launch_time=900)
    events=[];trace=[];nodes=Items();world=dict(lost_goal=False,bad_moon=False,edited=False)
    def patch(body,pe,epoch,ecc,next_patch=None,exit_ut=0):
        return NS(BODY=body,PERIAPSIS=pe,ECCENTRICITY=ecc,INCLINATION=0,PERIOD=20000,
                  ETA=EventEta(clock,epoch),HASNEXTPATCH=next_patch is not None,
                  NEXTPATCH=next_patch,NEXTPATCHETA=exit_ut-clock.SECONDS)
    def chain(axes):
        radial,normal,prograde=axes
        miss=math.hypot((10-radial)*400000,normal*300000)
        encountered=miss<ike.SOIRADIUS
        final_pe=(15000 if entry else 310000)-(radial-10)*5000+normal*1000
        final=patch(duna,final_pe,18000,1.1)
        moon=patch(ike,1000 if world['bad_moon'] else 30000,13000,2,
                   None if world['lost_goal'] else final,14000)
        transit=patch(duna,85000 if encountered else (5000 if entry else 300000),16000,1.5,
                      moon if encountered else patch(sun,1e10,30000,.1),12000 if encountered else 20000)
        initial=patch(sun,1e10,9000,.1,transit,10000)
        if departure:initial=patch(kerbin,80000,2500,1.1,initial,4000)
        return initial
    class Node:
        def __init__(self):self.TIME=2000 if departure else 5000;self.RADIALOUT=0;self.NORMAL=0;self.PROGRADE=900
        @property
        def ORBIT(self):return chain([self.RADIALOUT,self.NORMAL,self.PROGRADE])
        @property
        def DELTAV(self):return NS(MAG=math.sqrt(self.RADIALOUT**2+self.NORMAL**2+self.PROGRADE**2))
    nd=Node();nodes.append(nd)
    ship=NS(BODY=body,STATUS='ESCAPING',THRUST=0,DELTAV=NS(VACUUM=5000),ORBIT=chain([0,0,900]),
            CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    env=dict(TIME=clock,KUNIVERSE=NS(ACTIVEVESSEL=ship,REALTIME=100),SHIP=ship,WARP=0,ABORT=False,
        HASNODE=True,NEXTNODE=nd,ALLNODES=nodes,LIST=lambda *xs:Items(xs),LEXICON=lambda *xs:Map(zip(xs[::2],xs[1::2])),
        SQRT=math.sqrt,FLOOR=math.floor,stateGet=state.get,stateGetNum=state.get,
        maneuverBurnInterrupted=lambda:False,arrivalBurnSeconds=lambda dv:2*dv,
        fixture_bodies=lambda dest:dest.extend([sun,duna,ike,kerbin]),
        arrivalPatchPeUt=lambda p,start:clock.SECONDS+p.ETA.PERIAPSIS if clock.SECONDS+p.ETA.PERIAPSIS>start and (not p.HASNEXTPATCH or p.ETA.PERIAPSIS<p.NEXTPATCHETA) else -1,
        arrivalPatchRadiusUt=lambda p,alt,start:clock.SECONDS+p.ETA.PERIAPSIS-100)
    def wait(dt):
        clock.SECONDS+=dt;env['KUNIVERSE'].REALTIME+=dt
        trace.append((nd.RADIALOUT,nd.NORMAL,nd.PROGRADE))
    def position(obj,epoch):
        env['KUNIVERSE'].REALTIME+=.00001
        if obj is ike:return Vec((0,0,0))
        assert obj is ship
        # Smooth near-miss distance BEFORE the synthetic native moon patch
        # exists; crossing the toy SOI creates the encounter/exit patches.
        return Vec(((10-nd.RADIALOUT)*400000,nd.NORMAL*300000,(epoch-14000)*10))
    env.update(fixture_wait=wait,POSITIONAT=position)
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:call(name,env,*args)
    env['NATIVE_PROBE']=NS(CALL=env['assistSearchNativeProbe'])
    limits=env['assistSearchLimits']()
    # Caller must supply its existing planner's latest safe solve deadline.
    limits['STOP_UT']=clock.SECONDS+60
    # A real direct-arrival certificate for this synthetic world, independently
    # priced from the unassisted Duna patch, not from the trial's moon outcome.
    def direct(node,terminal,budget):
        events.append(('reference',node.RADIALOUT,node.NORMAL,node.PROGRADE))
        dv=node.DELTAV.MAG
        capture=0 if entry else math.sqrt(duna.MU*2.5/620000)-math.sqrt(duna.MU/620000)
        return Map(OK=True,BOUND='EXACT',GOAL=terminal.COPY,COST=dv+capture,NODE_DV=dv,UT=node.TIME)
    return env,nd,route,limits,NS(CALL=direct),state,world,events,trace


def search(env,nd,route,limits,direct):
    return env['searchAssistNode'](nd,route,0,direct,limits)


def check_acquisition_and_restore():
    for departure in (False,True):
        env,nd,route,limits,direct,state,world,events,trace=fixture(departure=departure)
        assert not env['assistEvaluate'](nd,route,env['assistRouteBodies'](route),0,'',env['SHIP'].BODY.NAME)['OK']
        before=dict(state)
        result=search(env,nd,route,limits,direct)
        assert result['OK'],result
        assert result['RESTORED'] and result['NEEDS_ADMISSION'] and not result['CANCELLED']
        assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
        assert result['TRIALS']<=limits['TRIALS'] and result['POSITIONS']<=limits['POSITIONS']
        assert result['EXTRA_DV']<=-25 and result['DIRECT_BOUND']=='EXACT'
        assert dict(state)==before and all(row[1:]==(0,0,900) for row in events)
        assert max(math.sqrt(rad**2+normal**2+(pro-900)**2) for rad,normal,pro in trace)<=20.00001
        # Review the returned vector using the ACTUAL shared final validator;
        # the live fallback node was left alone by the search.
        nd.RADIALOUT,nd.NORMAL,nd.PROGRADE=result['AXES']
        evidence=env['assistEvaluate'](nd,route,env['assistRouteBodies'](route),0,'',env['SHIP'].BODY.NAME)
        assert evidence['OK'] and evidence['COST']+limits['RESERVE_DV']<=env['SHIP'].DELTAV.VACUUM
    print('PASS: no encounter -> smooth closest approach -> wrong post-moon Pe -> full native-goal candidate; fixed epoch/vector cap, total-cost savings, budgets and original-node restoration hold in Sun and Kerbin-departure contexts')


def check_context_cancellation():
    for fault in ('abort','vector-edit','time-edit','removed','extra-node','active-vessel','body','phase','pilot','thrust','interrupted','wall','game'):
        env,nd,route,limits,direct,state,world,events,trace=fixture()
        wait=env['fixture_wait'];calls=[0]
        def stop(dt):
            wait(dt);calls[0]+=1
            if calls[0]!=1:return
            if fault=='abort':env['ABORT']=True
            if fault=='vector-edit':nd.NORMAL=77
            if fault=='time-edit':nd.TIME+=1
            if fault=='removed':env['ALLNODES'].clear();env['HASNODE']=False
            if fault=='extra-node':env['ALLNODES'].append(NS(TIME=6000))
            if fault=='active-vessel':env['KUNIVERSE'].ACTIVEVESSEL=NS()
            if fault=='body':env['SHIP'].BODY=NS(NAME='other')
            if fault=='phase':state['phase']='manual'
            if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
            if fault=='thrust':env['SHIP'].THRUST=1
            if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
            if fault=='wall':env['KUNIVERSE'].REALTIME+=100
            if fault=='game':env['TIME'].SECONDS+=100
        env['fixture_wait']=stop
        result=search(env,nd,route,limits,direct)
        assert not result['OK'],fault
        if fault=='vector-edit':assert nd.NORMAL==77 and not result['RESTORED']
        if fault=='time-edit':assert nd.TIME==5001 and not result['RESTORED']
        if fault in ('abort','wall','game','extra-node'):assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
        if fault=='extra-node':assert len(env['ALLNODES'])==2
    print('PASS: Abort and deadlines restore the owned node; edits/removal/vessel/frame/phase/control/burn changes cancel without overwriting takeover or deleting other nodes')


def check_cost_and_final_proof():
    for fault in ('fuel','unknown-bound','goal-mismatch','unsupported-goal','unsupported-flyby','unpriced-node','no-gain','final-goal-lost','final-reference-changed','reference-edit','positions'):
        env,nd,route,limits,direct,state,world,events,trace=fixture()
        assess=direct.CALL
        if fault=='fuel':env['SHIP'].DELTAV.VACUUM=950
        if fault=='positions':limits['POSITIONS']=24
        if fault=='unsupported-goal':route[-1]['LAN']=42
        if fault=='unsupported-flyby':route[0]['AP']=123456
        def reference(node,goal,budget):
            result=assess(node,goal,budget)
            if fault=='unknown-bound':result['BOUND']='GUESS'
            if fault=='goal-mismatch':result['GOAL']['AP']=500000
            if fault=='unpriced-node':result['NODE_DV']=0
            if fault=='no-gain':result['COST']=result['NODE_DV']
            if fault=='final-reference-changed' and len(events)>1:result['COST']=result['NODE_DV']
            if fault=='reference-edit':node.NORMAL=77
            return result
        direct.CALL=reference
        if fault=='final-goal-lost':
            native=env['assistSearchNativeProbe'];valid=[0]
            def probe(ctx,offsets,budget):
                if valid[0]>0:world['lost_goal']=True
                result=native(ctx,offsets,budget)
                if result['ELIGIBLE']:valid[0]+=1
                return result
            env['NATIVE_PROBE']=NS(CALL=probe)
        result=search(env,nd,route,limits,direct)
        assert not result['OK'],(fault,result)
        if fault=='reference-edit':assert nd.NORMAL==77 and not result['RESTORED'] and result['CANCELLED']
        else:assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
        if 'POSITIONS' in result:assert result['POSITIONS']<=limits['POSITIONS']
    print('PASS: fuel/reserve, certified direct cost/goal/node identity, resource exhaustion and fresh final candidate/reference checks cannot be replaced by a near encounter or cached score')


def check_entry_science_policy_and_limits():
    for allowance,accepted in ((0,False),(5,True)):
        env,nd,route,limits,direct,state,world,events,trace=fixture(entry=True)
        limits['SCIENCE_EXTRA_DV']=allowance
        result=search(env,nd,route,limits,direct)
        assert result['OK']==accepted,result
        assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
        if accepted:assert result['EXTRA_DV']<=allowance and result['NEEDS_ADMISSION']
    for key,value in (('TRIALS',1000),('TRIALS',4.5),('POSITIONS',24.5),('CHANGE_DV',float('nan')),('MIN_BURN_DV',.1),('RESERVE_DV',-1),('STOP_UT',0)):
        env,nd,route,limits,direct,_,_,events,trace=fixture()
        limits[key]=value
        result=search(env,nd,route,limits,direct)
        assert not result['OK'] and not trace and not events
    print('PASS: a free direct entry cannot justify a fuel-saving detour; extra science requires an explicit allowance, and invalid/minimum-weakening limits make no probes')


def check_final_reference_takeover():
    for fault in ('removed','active-vessel','vector-edit'):
        env,nd,route,limits,direct,state,world,events,trace=fixture()
        assess=direct.CALL
        delta=type(nd).DELTAV.fget
        def checked_delta(node):
            assert env['KUNIVERSE'].ACTIVEVESSEL is env['SHIP'] and node in env['ALLNODES'],'unsafe node API read'
            return delta(node)
        type(nd).DELTAV=property(checked_delta)
        def reference(node,goal,budget):
            result=assess(node,goal,budget)
            if len(events)>1:
                if fault=='removed':env['ALLNODES'].clear()
                if fault=='active-vessel':env['KUNIVERSE'].ACTIVEVESSEL=NS()
                if fault=='vector-edit':node.NORMAL=77
            return result
        direct.CALL=reference
        result=search(env,nd,route,limits,direct)
        assert not result['OK'] and result['CANCELLED'] and not result['RESTORED'],(fault,result)
        assert (nd.RADIALOUT,nd.PROGRADE)==(0,900)
        assert nd.NORMAL==(77 if fault=='vector-edit' else 0)
    print('PASS: takeover during the final direct-reference callback rejects without reading an inactive/removed node or overwriting its edited vector')


def check_departure_rule_and_manual_isolation():
    env,nd,route,limits,direct,_,_,_,_=fixture(departure=True)
    nd.RADIALOUT=12.5
    bodies=env['assistRouteBodies'](route)
    assert not env['assistEvaluate'](nd,route,bodies)['OK']
    assert env['assistEvaluate'](nd,route,bodies,0,'','Kerbin')['OK']
    for fault in ('wrong-name','atmosphere','inward'):
        saved=nd.ORBIT
        if fault=='wrong-name':name='other'
        else:name='Kerbin'
        if fault=='atmosphere':env['SHIP'].BODY.ATM.HEIGHT=90000
        if fault=='inward':env['SHIP'].BODY.BODY=NS(NAME='unrelated')
        assert not env['assistEvaluate'](nd,route,bodies,0,'',name)['OK'],fault
        env,nd,route,limits,direct,_,_,_,_=fixture(departure=True);nd.RADIALOUT=12.5
        bodies=env['assistRouteBodies'](route)
    assert not env['assistRouteBodies'](Items([route[-1]]))
    assert env['assistRouteBodies'](Items([route[-1]]),1)
    assert not unscoped_returns(SEARCH) and not negated_defined_conditions(SEARCH)
    assert not re.search(r'(?m)^\s*(?:ADD|REMOVE|STAGE|REBOOT|LOCK|UNLOCK|LOG)\b|\b(?:stateSet|executeManeuver|missionOverrideUpdate)\s*\(',mask(SEARCH))
    production='\n'.join((ROOT/f'lib/{name}.ks').read_text() for name in ('dependencies','xfer_plan','arrival_bplane','capture','assist_plan'))
    assert 'searchAssistNode' not in production and 'assist_search_native' not in production
    print('PASS: departure escape is explicit and outward-only with existing clearance guards; live two-leg defaults remain, single terminal is opt-in, and manual acquisition has no phase/execution/state/staging hooks')


if __name__=='__main__':
    check_acquisition_and_restore()
    check_context_cancellation()
    check_cost_and_final_proof()
    check_entry_science_policy_and_limits()
    check_final_reference_takeover()
    check_departure_rule_and_manual_isolation()
