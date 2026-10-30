"""Manual command and direct-capture baseline; synthetic conics, not KSP."""
import ast
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS
import check_landing_guidance as ks
import check_assist_search as search
from check_codebase import ROOT,function_body,mask,closure,dependency_tables,command_entrypoint_errors
from check_espoir_fleet import Map,Items,profile
from arrival_fixture import EventEta

PREVIEW=(ROOT/'lib/assist_preview.ks').read_text()
COMMAND=(ROOT/'cmd/assistsearch.ks').read_text()


@lru_cache(None)
def prepared(name):
    code=function_body(PREVIEW,name)
    params=re.findall(r'PARAMETER (\w+)',code)
    nodes=ks.parse(code)
    if name=='assistPreviewPatchRows':
        def instrument(rows):
            output=[]
            for text,yes,no in rows:
                if text.startswith('diagnosticArchiveLine('):
                    text='fixture_warning()' if 'prediction-warning' in text else 'fixture_patch()'
                output.append((text,instrument(yes),instrument(no)))
            return output
        nodes=instrument(nodes)
    return params,ks.compile_nodes(ks.freeze(nodes))


def call(name,env,*args):
    params,code=prepared(name)
    local=dict(env);local.update(zip(params,args))
    try:ks.execute(code,local)
    except ks.Returned as result:return result.value


def fixture(**kwargs):
    env,nd,route,limits,direct,state,world,events,trace=search.fixture(**kwargs)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',PREVIEW):
        env[name]=lambda *args,name=name:call(name,env,*args)
    fallback=route[-1].COPY
    direct=NS(CALL=lambda node,goal,budget:env['assistPreviewDirect'](node,goal,budget,fallback))
    return env,nd,route,limits,direct,state,world,events,trace,fallback


def check_actual_direct_baseline():
    for departure in (False,True):
        env,nd,route,limits,direct,state,world,events,trace,fallback=fixture(departure=departure)
        before=dict(state)
        proof=direct.CALL(nd,route[-1],env['assistSearchBudget'](limits))
        expected=900+math.sqrt(3.0136321e11*2.5/620000)-math.sqrt(3.0136321e11/620000)
        assert proof['OK'] and proof['BOUND']=='EXACT' and abs(proof['COST']-expected)<1e-8,proof
        result=search.search(env,nd,route,limits,direct)
        assert result['OK'] and result['RESTORED'] and result['EXTRA_DV']<=-25,result
        assert result['CAPTURE_DV']>0 and [leg['BODY'] for leg in result['LEGS']]==['Ike','Duna']
        assert sum(result['TIERS'])==result['TRIALS'] and result['BEST_TIER']==3
        assert dict(state)==before and (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
    # A required paid parent capture is only a prefix of the final moon goal.
    env,nd,_,limits,_,_,_,_,_,fallback=fixture()
    terminal=Map(BODY='Ike',MIN_PE=25000,MAX_PE=30000,AP=75000)
    proof=env['assistPreviewDirect'](nd,terminal,env['assistSearchBudget'](limits),fallback)
    assert proof['OK'] and proof['BOUND']=='LOWER' and proof['PRICED_BODY']=='Duna'
    for fault in ('unmet-plane','bad-pe','unsupported','deadline'):
        env,nd,route,limits,direct,_,_,_,_,fallback=fixture()
        if fault=='unmet-plane':fallback.update(INC=90,INC_TOL=.2)
        if fault=='bad-pe':fallback.update(MIN_PE=1000,MAX_PE=2000)
        if fault=='unsupported':fallback['LAN']=123
        budget=env['assistSearchBudget'](limits)
        if fault=='deadline':budget['GAME_END']=env['TIME'].SECONDS
        proof=env['assistPreviewDirect'](nd,route[-1],budget,fallback)
        assert not proof['OK'],(fault,proof)
        assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
    print('PASS: real preview baseline acquires a missing encounter with verified total savings and restoration; equivalent direct capture is EXACT, mandatory parent prefix LOWER, unsafe/unpriced goals and deadlines reject')


def check_already_planned_capture():
    env,_,route,limits,_,state,_,_,_,fallback=fixture()
    duna=env['assistRouteBodies'](Items([fallback]),1)[0]
    patch=NS(BODY=duna,PERIAPSIS=300000,APOAPSIS=300000,ECCENTRICITY=0,INCLINATION=0,HASNEXTPATCH=False)
    nd=NS(ORBIT=patch,DELTAV=NS(MAG=123),TIME=5000)
    proof=env['assistPreviewDirect'](nd,route[-1],env['assistSearchBudget'](limits),fallback)
    assert proof['OK'] and proof['COST']==123 and proof['CAPTURE_DV']==0 and proof['BOUND']=='EXACT'
    patch.INCLINATION=90;fallback.update(INC=0,INC_TOL=.2)
    assert not env['_assistPreviewBoundGoal'](patch,fallback)
    patch.INCLINATION=0;patch.HASNEXTPATCH=True
    assert not env['_assistPreviewBoundGoal'](patch,fallback)
    print('PASS: an already-achieving bound capture node is priced once; wrong-plane and outgoing partial captures cannot masquerade as the final orbit')


def rough_entry_fixture():
    env,nd,route,limits,direct,state,world,events,trace,fallback=fixture(entry=True,departure=True)
    # Native-reported first-run Duna miss; response to trial vectors remains
    # synthetic. Only the baseline gets the logged19,907,948.56m periapsis.
    original=type(nd).ORBIT.fget
    def orbit(node):
        root=original(node);patch=root
        while patch.BODY.NAME!='Duna':patch=patch.NEXTPATCH
        if patch.NEXTPATCH.BODY.NAME!='Ike':
            patch.PERIAPSIS=19907948.5609205
            if world.get('truncated'):patch.ETA=EventEta(env['TIME'],25000)
            if world.get('below-atmosphere'):patch.PERIAPSIS=1000
            if world.get('open-tail'):patch.HASNEXTPATCH=False
        return root
    type(nd).ORBIT=property(orbit)
    return env,nd,route,limits,direct,state,world,events,trace,fallback


def check_rough_entry_departure():
    env,nd,route,limits,direct,state,world,events,trace,fallback=rough_entry_fixture()
    before=dict(state)
    nd.RADIALOUT=19.9999999999994;nd.NORMAL=-79.5907035875978;nd.PROGRADE=1060.74524651039
    # Native DELTAV differs slightly from the PRN Euclidean norm in this log.
    # Price the measured API value, not a recomputation from printed axes.
    delta=type(nd).DELTAV
    type(nd).DELTAV=property(lambda node:NS(MAG=1063.91065508142))
    budget=env['assistSearchBudget'](limits)
    assert not env['assistEvaluate'](nd,Items([fallback]),env['assistRouteBodies'](Items([fallback]),1),0,'','Kerbin')['OK']
    reference=direct.CALL(nd,route[-1],budget)
    assert reference['OK'] and reference['BOUND']=='LOWER' and reference['SOURCE']=='departure-only-pending-entry'
    assert abs(reference['COST']-1063.91065508142)<1e-7 and reference['CAPTURE_DV']==0
    assert reference['GOAL']==route[-1] and state==before
    type(nd).DELTAV=delta
    nd.RADIALOUT=0;nd.NORMAL=0;nd.PROGRADE=900
    # With enough search radius an actual complete native response is still
    # mandatory; a lower bound is not a waiver of the candidate's entry gate.
    limits['CHANGE_DV']=50
    result=search.search(env,nd,route,limits,direct)
    assert result['OK'] and result['TRIALS']>1 and result['RESTORED'],result
    assert result['DIRECT_BOUND']=='LOWER' and result['DIRECT_SOURCE']=='departure-only-pending-entry'
    assert result['COST']+25<=900
    assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900) and state==before
    nd.RADIALOUT,nd.NORMAL,nd.PROGRADE=result['AXES']
    evidence=env['assistEvaluate'](nd,route,env['assistRouteBodies'](route),0,'','Kerbin')
    assert evidence['OK'] and 2000<=evidence['LEGS'][-1]['PE']<=8000
    for fault in ('truncated','below-atmosphere','wrong-phase','wrong-body'):
        env,nd,route,limits,direct,state,world,events,trace,fallback=rough_entry_fixture()
        if fault in ('truncated','below-atmosphere'):world[fault]=True
        if fault=='wrong-phase':state['phase']='REFINE_BPLANE'
        if fault=='wrong-body':env['SHIP'].BODY=env['assistRouteBodies'](Items([fallback]),1)[0]
        reference=direct.CALL(nd,route[-1],env['assistSearchBudget'](limits))
        assert not reference['OK'],(fault,reference)
    print('PASS: reported1063.91m/s XING/19,908km Duna Pe gets a departure-only LOWER baseline; search can then prove full entry, while unsafe prefixes and non-XING contexts reject')


def check_rough_entry_preserves_goal_and_horizon():
    for fault in ('lost_goal','bad_moon'):
        env,nd,route,limits,direct,state,world,events,trace,fallback=rough_entry_fixture()
        world[fault]=True;limits['CHANGE_DV']=50
        result=search.search(env,nd,route,limits,direct)
        assert not result['OK'] and result['TRIALS']>1 and result['RESTORED']
        assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900)
    for open_tail in (False,True):
        env,nd,route,limits,direct,state,world,events,trace,fallback=rough_entry_fixture()
        world['open-tail']=open_tail
        env.update(fixture_warning=lambda:events.append('open-tail'),fixture_patch=lambda:events.append('patch'))
        env['assistPreviewPatchRows'](nd,Map())
        assert ('open-tail' in events)==open_tail
        assert events.count('patch')==(3 if open_tail else 4)
    assert 'careerPatchesAhead=' in COMMAND and 'CAREER():PATCHLIMIT' in COMMAND
    assert 'schema=2' in COMMAND and 'configLiteral(route)' in COMMAND
    print('PASS: a rough entry baseline cannot admit a missing terminal entry or unsafe moon; prediction-ended escape patches are diagnosed and compact reports include the career lookahead limit')


def check_capture_search_radius():
    # Synthetic native response, not a physical Ike flyby: a partial capture
    # opens the moon route, whose later capture costs17m/s instead of300m/s.
    for radius,accepted in ((20,False),(50,True)):
        env,old_node,route,limits,_,state,_,_,_,fallback=fixture()
        clock=env['TIME'];duna,ike=env['assistRouteBodies'](Items([fallback,Map(BODY='Ike',MIN_PE=25000,AP=75000)]))
        def patch(body,pe,ecc,epoch,next_patch=None,exit_ut=0):
            return NS(BODY=body,PERIAPSIS=pe,APOAPSIS=300000,ECCENTRICITY=ecc,INCLINATION=0,PERIOD=20000,
                ETA=EventEta(clock,epoch),HASNEXTPATCH=next_patch is not None,NEXTPATCH=next_patch,NEXTPATCHETA=exit_ut-clock.SECONDS)
        final=patch(duna,300000,.05,18000)
        moon=patch(ike,30000,2,13000,final,14000)
        partial=patch(duna,300000,.8,16000,moon,12000)
        captured=patch(duna,300000,0,6000)
        class Node:
            TIME=5000;RADIALOUT=0;NORMAL=0;PROGRADE=-300
            @property
            def DELTAV(self):return NS(MAG=math.sqrt(self.RADIALOUT**2+self.NORMAL**2+self.PROGRADE**2))
            @property
            def ORBIT(self):return partial if self.PROGRADE>=-270 else captured
        nd=Node();env['ALLNODES'].clear();env['ALLNODES'].append(nd);env['NEXTNODE']=nd
        env['SHIP'].BODY=duna;env['SHIP'].ORBIT=patch(duna,300000,1.5,8000)
        state['phase']='CAPTURE';limits['CHANGE_DV']=radius
        direct=NS(CALL=lambda node,goal,budget:env['assistPreviewDirect'](node,goal,budget,fallback))
        result=search.search(env,nd,route,limits,direct)
        assert result['OK']==accepted,result
        assert (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,-300)
        if accepted:assert result['DIRECT_COST']==300 and result['EXTRA_DV']<=-25
    print('PASS: a20m/s radius cannot net25m/s on a300m/s planned capture;50m/s permits a useful synthetic partial-capture assist, prices future capture and restores the original node')


def check_mission_policy_and_seek():
    for name in ('duna_orbital_surveyor','ike_orbital_surveyor','ike_lander','duna_impactor','duna_science_impact'):
        env,nd,route,limits,_,_,_,_,_,_=fixture()
        env.update(BPLANE_ARRIVAL_MODE='ORBIT')
        env.update(profile(name))
        fallback=env['assistPreviewMissionFallback']()
        assert fallback['BODY']=='Duna' and env['assistRouteBodies'](Items([fallback]),1),name
        if 'impactor' in name or name=='duna_science_impact':
            if name.startswith('duna_'):assert fallback['MODE']=='ENTRY' and 'AP' not in fallback
        if name.startswith('ike_'):assert fallback['AP']==2880000
        if name=='duna_orbital_surveyor':assert fallback['INC']==90 and fallback['AP']==300000
        assert env['assistPreviewSeekIndex'](nd,route)==0
        parent_first=Items([Map(BODY='Duna',MIN_PE=75000),Map(BODY='Ike',MIN_PE=25000,AP=75000)])
        assert env['assistPreviewSeekIndex'](nd,parent_first)==1
    print('PASS: all five real Espoir profiles supply their own fallback capture/entry policy; seek chooses the missing moon leg rather than refining an already-predicted parent encounter')


@lru_cache(None)
def command_code():
    code=function_body(COMMAND,'_cmdAssistsearch')
    nested=function_body(COMMAND,'direct')
    code=code.replace('LOCAL FUNCTION direct {'+nested+'}','')
    code=code.replace('direct@','DIRECT')
    code=re.sub(r'IF DEFINED (\w+)',r'IF fixture_defined("\1")',code)
    def strip(nodes):
        rows=[]
        for text,yes,no in nodes:
            if text.startswith('PRINT '):continue
            if text.startswith('diagnosticArchiveLine('):text='fixture_report()'
            rows.append((text,strip(yes),strip(no)))
        return rows
    return ks.compile_nodes(ks.freeze(strip(ks.parse(code))))


def check_command_control_flow():
    faults=('ok','offline','abort','pilot','warp','imminent','extra-node','no-node','no-engines','loading-change','empty-route','missing-profile','unpriced','incomplete-report','generated-profile')
    for fault in faults:
        env,nd,route,limits,_,state,_,_,trace,fallback=fixture()
        events=[];results=[];before=dict(state)
        nd.ETA=nd.TIME-env['TIME'].SECONDS
        env.update(route=Items(),fallbackGoal=Map(),reserveDv=-1,changeDv=50,scienceExtraDv=0,seekIndex=-1,
            HOMECONNECTION=NS(ISCONNECTED=fault!='offline'),CORE=NS(),CONFIG=NS(IPU=2000),
            bootPreamble=lambda:events.append('preamble'),bootLibLoad=lambda name:events.append(('load',name)),
            bootLocalScriptPath=lambda _: '1:/mission.ks' if fault!='missing-profile' else '',
            bootArchivePath=lambda _:'0:/mission.ks',EXISTS=lambda path:fault!='missing-profile' and (fault!='generated-profile' or path!='0:/mission.ks'),
            applyMissionOverrides=lambda:events.append('overrides'),
            diagnosticArchiveOpen=lambda _:Map(READY=True,COMPLETE=fault!='incomplete-report'),diagnosticArchiveClose=lambda *_:True,
            fixture_report=lambda:events.append('report'),
            assistPreviewPatchRows=lambda *_:None,
            assistPreviewResult=lambda result,_:results.append(result),
            fixture_defined=env.__contains__)
        state.update(vehicle='Espoir',mission_id='test')
        before=dict(state)
        def load(path):
            events.append(('run',path))
            if path in ('1:/mission.ks','0:/mission.ks'):
                env.update(MISSION_ASSIST_ROUTE=Items() if fault=='empty-route' else route,
                    BPLANE_ARRIVAL_MODE='ORBIT',TARGET_='Duna',CAPTURE_PE=300000,
                    CAPTURE_MIN_PE=295000,CAPTURE_MAX_PE=300000,TARGET_AP=300000,
                    CAPTURE_LAN=-1,CAPTURE_AOP=-1,BPLANE_REQUIRE_PLANE=0,
                    ASSIST_RESERVE_DV=120,CAPTURE_RESERVE_DV=150)
            if fault=='loading-change':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        env.update(RUNPATH=load,RUNONCEPATH=load)
        env['DIRECT']=NS(CALL=lambda node,goal,budget:env['assistPreviewDirect'](node,goal,budget,env['fallbackGoal']))
        if fault=='abort':env['ABORT']=True
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='warp':env['WARP']=1
        if fault=='imminent':nd.ETA=200
        if fault=='extra-node':env['ALLNODES'].append(NS())
        if fault=='no-node':env['HASNODE']=False
        if fault=='no-engines':env['arrivalBurnSeconds']=lambda _: -1
        if fault=='unpriced':env['assistPreviewMissionFallback']=lambda:Map(BODY='Duna',MIN_PE=1000,MAX_PE=2000,AP=300000)
        try:ks.execute(command_code(),env)
        except ks.Returned:pass
        assert state==before and (nd.RADIALOUT,nd.NORMAL,nd.PROGRADE)==(0,0,900),fault
        assert len(results)==(1 if fault in ('ok','unpriced','generated-profile') else 0),(fault,results)
        if fault in ('ok','generated-profile'):
            assert results[0]['OK'] and results[0]['RESTORED'] and env['limits']['RESERVE_DV']==150
            assert 'report' in events and events.index('overrides')<events.index('report')
            assert env['limits']['STOP_UT']<nd.TIME-180
            assert ('run','1:/mission.ks' if fault=='generated-profile' else '0:/mission.ks') in events
        if fault=='unpriced':assert not results[0]['OK'] and not trace
    assert not command_entrypoint_errors(COMMAND)
    assert 'PARAMETER changeDv IS 50.' in COMMAND
    forbidden=r'(?m)^\s*(?:ADD|REMOVE|STAGE|REBOOT|LOCK|UNLOCK|SET WARP)\b|\b(?:stateSet|stateRemove|executeManeuver|CREATEALARM|DELETEALARM|bootApplyMissionConfig)\s*\('
    assert not re.search(forbidden,mask(COMMAND+'\n'+PREVIEW))
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for roots in phases.values():assert not {'assist_search','assist_search_native','assist_preview'}&closure(roots,deps)
    print('PASS: actual manual command loads/replays config only, archives before probing, preserves node/mission/controls/alarms, refuses unsafe contexts and leaves new search modules outside every phase closure')


if __name__=='__main__':
    check_actual_direct_baseline()
    check_already_planned_capture()
    check_rough_entry_departure()
    check_rough_entry_preserves_goal_and_horizon()
    check_capture_search_radius()
    check_mission_policy_and_seek()
    check_command_control_flow()
