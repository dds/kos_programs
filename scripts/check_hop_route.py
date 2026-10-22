"""Source-driven route/reboot/ignition contracts; no KSP hop flight runner."""
import json
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, mask, command_entrypoint_errors, dependency_tables, closure
from check_runtime_contracts import KList

HOP=(ROOT/'lib/hop.ks').read_text()


def without_prints(nodes):
    return [(statement,without_prints(yes),without_prints(no)) for statement,yes,no in nodes
            if not statement.startswith('PRINT ')]


def execute(name,env,*args):
    source=function_body(HOP,name)
    params=re.findall(r'PARAMETER (\w+)',source)
    local=dict(env);local.update(zip(params,args))
    source=source.replace('UNTIL ABORT','UNTIL route_cancelled()')
    source=source.replace('UNLOCK STEERING.','unlock_steering().').replace('REBOOT.','reboot().')
    try:ks.run(without_prints(ks.parse(source)),local)
    except ks.Returned as result:return result.value


class Items(KList):
    def CONTAINS(self,item):return item in self


class Reboot(Exception):pass


def fixture():
    state=dict(hop_route_active=True,hop_route_body='Minmus',hop_route_index=0,
               hop_route_sites=KList([KList([0,1]),KList([0,2])]),hop_inflight=True,
               hop_route_restore=dict(SEQUENCE=Items(['LAND_ASSIST','SURFACE_RETURN_SETUP']),
                                      RETURN_PE=53000,LANDING_FLEXIBLE_SITE=1))
    updates={};events=[];keys=[]
    def reload(reason,phase,band):state.update(phase=phase,lib_band=band,reload_reason=reason)
    def reboot():raise Reboot()
    def wait(seconds):
        if not keys:env['ABORT']=True
    env=dict(stateGet=lambda key,default='':state.get(key,default),
             stateGetNum=lambda key,default=0:state.get(key,default),
             stateSet=lambda key,value:state.update({key:value}),stateRemove=lambda key:state.pop(key,None),stateSaveReloadState=reload,
             missionOverrideUpdate=lambda values:updates.update(values),
             LIST=lambda *args:KList(args),LEXICON=lambda *args:dict(zip(args[::2],args[1::2])),
             SHIP=NS(STATUS='LANDED',LATITUDE=0,LONGITUDE=1,ALTITUDE=0,
                     BODY=NS(NAME='Minmus',RADIUS=60000,MU=.491*60000**2),DELTAV=NS(VACUUM=2000)),
             STAGE=NS(DELTAV=NS(VACUUM=1300)),MIN=min,MAX=max,SQRT=math.sqrt,
             SIN=lambda value:math.sin(math.radians(value)),HOP_PITCH=45,
             HOP_RETURN_RESERVE_DV=700,HOP_LANDING_RESERVE_DV=180,
             ABORT=False,ROUND=round,bootLibBandForPhase=lambda name:'RETURN_SETUP',
             _hopRestoreSavedLimits=lambda:None,thrustCutoffOk=lambda:events.append('cutoff') or True,unlock_steering=lambda:events.append('unlock'),
             yieldToPrompt=lambda:events.append('yield'),reboot=reboot,fixture_wait=wait,route_cancelled=lambda:env['ABORT'],
             geoDistance=lambda *args:1000,mLogError=lambda *args:None)
    class Input:
        @property
        def HASCHAR(self):return bool(keys)
        def GETCHAR(self):return keys.pop(0)
    env['TERMINAL']=NS(INPUT=Input())
    for name in ('hopRouteBudget','hopRouteFuelOk'):
        env[name]=lambda *args,name=name:execute(name,env,*args)
    return env,state,updates,events,keys


def check_review_and_reboot():
    env,state,updates,events,keys=fixture()
    execute('phaseHopReview',env)
    assert events==['cutoff','unlock','yield'] and state['hop_route_index']==0
    assert not state['hop_inflight'] and not updates
    env['ABORT']=False;keys.append('n')
    try:execute('phaseHopReview',env)
    except Reboot:pass
    else:raise AssertionError('no next-leg reboot')
    # JSON round trip stands for state surviving the band reboot.
    saved=json.loads(json.dumps(state))
    saved['hop_route_restore']['SEQUENCE']=Items(saved['hop_route_restore']['SEQUENCE'])
    assert saved['hop_route_index']==0 and saved['hop_route_pending']==1 and saved['phase']=='HOP'
    assert updates==dict(HOP_TARGET_LAT=0,HOP_TARGET_LNG=2)
    # A second boot between committing index and deleting pending is harmless.
    execute('_hopApplyPending',env)
    state['hop_route_pending']=1
    execute('_hopApplyPending',env)
    assert state['hop_route_index']==1 and 'hop_route_pending' not in state
    saved['hop_route_index']=1
    saved.pop('hop_route_pending',None)
    env['stateGet']=lambda key,default='':saved.get(key,default)
    env['stateGetNum']=lambda key,default=0:saved.get(key,default)
    env['ABORT']=False;keys.append('r')
    try:execute('phaseHopReview',env)
    except Reboot:pass
    assert state['phase']=='SURFACE_RETURN_SETUP'
    assert updates['RETURN_PE']==53000 and updates['LANDING_FLEXIBLE_SITE']==1
    assert updates['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP']
    print('PASS: every landing remains unpowered for review; explicit N advances one persisted site, explicit R restores the original sequence/return policy without changing mission identity')


def check_budget_and_recovery():
    env,state,updates,events,keys=fixture()
    for available,stage,allowed in ((2000,1300,True),(800,1300,False),(2000,100,False)):
        env['SHIP'].DELTAV.VACUUM=available;env['STAGE'].DELTAV.VACUUM=stage
        assert env['hopRouteFuelOk'](1000)==allowed
    env['SHIP'].DELTAV.VACUUM=800;keys.append('n')
    execute('phaseHopReview',env)
    assert not updates and state['hop_route_index']==0
    phase=function_body(HOP,'phaseHop')
    assert phase.index('IF SHIP:STATUS <> "LANDED"')<phase.index('stateSet("hop_inflight",TRUE)')
    assert re.search(r'_hopPrepLandingAssist\(\)\.\s*REBOOT\.',phase)
    assert 'HOP_SURFACE_RECOVERY' in phase and 'HOP_REVIEW' in phase
    assert 'HOP_ROUTE' not in function_body(HOP,'_hopCaptureThrustLimits')
    assert not re.search(r'\bSTAGE\s*\.',mask(HOP))
    assert not re.search(r'SET ABORT TO FALSE',mask(HOP))
    assert phase.index('ignition alignment not achieved')<phase.index('LOCK THROTTLE TO hopThrottle')
    assert 'SET hopThrottle TO 0.' in phase and 'VDOT(SHIP:FACING:FOREVECTOR,SHIP:UP:VECTOR) > 0' in phase
    assert 'thrustCutoffOk().' in phase
    print('PASS: whole-vessel and permitted-stage budgets protect return and landing allowances; interrupted launch goes to descent/review, no hop stages or clears Abort, and initial/live actual-attitude guards own throttle')


def check_command_and_offline_band():
    cmd=(ROOT/'cmd/hoproute.ks').read_text()
    assert not command_entrypoint_errors(cmd)
    source=function_body(cmd,'_cmdHoproute')
    for unsafe in ('STAGE.','LOCK THROTTLE','REBOOT.','missionOverrideClear','missionProfileBegin'):
        assert unsafe not in mask(cmd),unsafe
    assert 'SHIP:STATUS <> "LANDED"' in source and 'HASNODE' in source
    assert 'landingTerrainGrade' in source and 'grade > TAN(LANDING_TERRAIN_MAX_SLOPE)' in source
    assert 'hop_route_restore' in source and 'hop_route_sites' in source
    assert 'bootApplyMissionConfig' in source
    assert 'mission_id", "hop"' not in source
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'hop' in closure(phases['hop_review'],deps)
    assert 'hop_review' in bands['hop']
    conditional=function_body((ROOT/'lib/mission_type.ks').read_text(),'missionTypeConditionalRoots')
    assert 'SEQUENCE:CONTAINS("HOP_REVIEW")' in conditional
    assert '"hop","landing_main","landing_coast","landing_brake"' in conditional
    assert conditional.index('bandKey = "HOP" OR bandKey = "LANDING"')<conditional.index('roots:ADD(ln)')
    print('PASS: route setup never ignites/reboots, checks sites/terrain and preserves current mission; only route bands retain launch, landing and review code through disconnected reboots')



def check_route_command_execution():
    cmd=(ROOT/'cmd/hoproute.ks').read_text()
    source=function_body(cmd,'_cmdHoproute')
    source=source.replace('RUNPATH("1:/lib/boot_lib").','')
    for failure in ('valid','abort','node','not-landed','atmosphere','raw','pilot','physical','stage-budget','terrain','long-leg'):
        env,state,updates,events,keys=fixture()
        state['hop_route_active']=False
        env['SHIP'].BODY.ATM=NS(EXISTS=False)
        env['SHIP'].THRUST=0;env['SHIP'].CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
        env.update(HASNODE=False,sites=KList([KList([0,1]),KList([0,2])]),returnReserveDv=700,
                   toleranceM=750,pitchDeg=45,maxBurnSeconds=90,maxApKm=5,hopTwr=2.5,
                   bootPreamble=lambda:None,bootLibLoad=lambda *args:None,
                   bootApplyMissionConfig=lambda *args:True,HOMECONNECTION=NS(ISCONNECTED=True),
                   vesselLandingPrepareRoles=lambda:True,SEQUENCE=Items(['LAND_ASSIST','SURFACE_RETURN_SETUP']),
                   TARGET_LAT=0,TARGET_LNG=0,TARGET_LOCK=0,TARGET_WAYPOINT='',LANDING_USE_WAYPOINTS=0,
                   LANDING_FLEXIBLE_SITE=1,LANDING_ECONOMY_BRAKE=1,LANDING_STAGE_BRAKE_CREDIT=1,
                   LANDING_POWERED_LEAD=0,LANDING_STAGE_DISCARD_HSPEED=0,RELOAD_AFTER_LAND_ASSIST=0,LANDING_TERRAIN_MAX_SLOPE=5,
                   ABS=abs,TAN=lambda value:math.tan(math.radians(value)),landingTerrainGrade=lambda *args:0)
        if failure=='abort':env['ABORT']=True
        if failure=='node':env['HASNODE']=True
        if failure=='not-landed':env['SHIP'].STATUS='FLYING'
        if failure=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if failure=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if failure=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if failure=='physical':env['SHIP'].THRUST=1
        if failure=='stage-budget':env['STAGE'].DELTAV.VACUUM=100
        if failure=='terrain':env['landingTerrainGrade']=lambda *args:1
        if failure=='long-leg':env['geoDistance']=lambda *args:20000
        try:ks.run(without_prints(ks.parse(source)),env)
        except ks.Returned:pass
        assert bool(updates)==(failure=='valid'),failure
        assert state['hop_route_active']==(failure=='valid'),failure
        if failure=='valid':
            assert state['phase']=='HOP' and state['hop_route_restore']['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP']
            assert 'mission_id' not in state and updates['HOP_RETURN_RESERVE_DV']==700
    print('PASS: actual command configures without launching, retains restore intent, and rejects Abort/nodes/non-surface/atmosphere/throttle/terrain/range/insufficient permitted-stage fuel before saving a route')


def check_limits_and_finish():
    env,state,updates,events,keys=fixture()
    engine1=NS(UID=101,THRUSTLIMIT=100);engine2=NS(UID=102,THRUSTLIMIT=80)
    env['SHIP'].ENGINES=KList([engine1,engine2])
    limits=execute('_hopCaptureThrustLimits',env)
    assert limits==[dict(UID=101,LIMIT=100),dict(UID=102,LIMIT=80)]
    engine1.THRUSTLIMIT=15;engine2.THRUSTLIMIT=20
    env['SHIP'].ENGINES=KList([engine2,engine1])
    execute('_hopRestoreThrustLimits',env,limits)
    assert engine1.THRUSTLIMIT==100 and engine2.THRUSTLIMIT==80
    state['hop_route_restore']['SEQUENCE']=Items(['PRELAUNCH','LAUNCH','PARK','RETURN_SETUP'])
    keys.append('r')
    try:execute('phaseHopReview',env)
    except Reboot:pass
    assert state['phase']=='PRELAUNCH' and not state['hop_route_active']
    # Review's local SEQUENCE assignment deliberately only controls the saved
    # handoff; the selected original profile is re-applied on reboot.
    phase=function_body(HOP,'phaseHop')
    assert phase.index('thrustCutoffOk()')<phase.index('_hopRestoreSavedLimits()')
    assert phase.index('IF NOT stopped')<phase.rindex('_hopRestoreSavedLimits()')
    assert 'SHIP:ALTITUDE+MIN(configMaxAp' in phase
    print('PASS: saved limiter values identify engines by UID across reordered parts; restoration follows physical cutoff, elevated launch terrain does not trip the Ap cap, and finishing an already-generated ascent leg resumes PRELAUNCH')


if __name__=='__main__':
    check_review_and_reboot()
    check_budget_and_recovery()
    check_command_and_offline_band()
    check_route_command_execution()
    check_limits_and_finish()
