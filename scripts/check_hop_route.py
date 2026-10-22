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
    source=source.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    source=source.replace('UNLOCK STEERING.','unlock_steering().').replace('REBOOT.','reboot().')
    try:ks.run(without_prints(ks.parse(source)),local)
    except ks.Returned as result:return result.value


class Items(KList):
    def CONTAINS(self,item):return item in self


class Lex(dict):
    LENGTH=property(len)


class Reboot(Exception):pass


def fixture():
    state=dict(phase='HOP_REVIEW',hop_route_active=True,hop_route_body='Minmus',hop_route_index=0,
               hop_route_sites=KList([KList([0,1]),KList([0,2])]),hop_inflight=True,
               hop_route_restore=Lex(SEQUENCE=Items(['LAND_ASSIST','SURFACE_RETURN_SETUP']),
                                      RETURN_PE=53000,LANDING_FLEXIBLE_SITE=1))
    updates={};events=[];keys=[]
    def reload(reason,phase,band):state.update(phase=phase,lib_band=band,reload_reason=reason)
    def reboot():raise Reboot()
    def wait(seconds):env['TIME'].SECONDS+=seconds
    env=dict(stateGet=lambda key,default='':state.get(key,default),
             stateGetNum=lambda key,default=0:state.get(key,default),
             stateSet=lambda key,value:state.update({key:value}),stateRemove=lambda key:state.pop(key,None),stateSaveReloadState=reload,
             missionOverrideUpdate=lambda values:updates.update(values),
             LIST=lambda *args:KList(args),LEXICON=lambda *args:Lex(zip(args[::2],args[1::2])),
             SHIP=NS(STATUS='LANDED',LATITUDE=0,LONGITUDE=1,ALTITUDE=0,
                     BODY=NS(NAME='Minmus',ATM=NS(EXISTS=False),RADIUS=60000,MU=.491*60000**2),DELTAV=NS(VACUUM=2000),
                     VELOCITY=NS(SURFACE=NS(MAG=0))),
             STAGE=NS(DELTAV=NS(VACUUM=1300)),MIN=min,MAX=max,SQRT=math.sqrt,
             SIN=lambda value:math.sin(math.radians(value)),HOP_PITCH=45,
             HOP_RETURN_RESERVE_DV=700,HOP_LANDING_RESERVE_DV=180,
             ABORT=False,HASNODE=False,TIME=NS(SECONDS=0),ABS=abs,CHAR=chr,TAN=lambda value:math.tan(math.radians(value)),
             LANDING_TERRAIN_MAX_SLOPE=5,landingTerrainGrade=lambda *args:0,
             vesselLandingPrepareRoles=lambda:True,selectedWaypoint=lambda:0,ROUND=round,bootLibBandForPhase=lambda name:'RETURN_SETUP',fixture_settle=lambda:None,
             _hopRestoreSavedLimits=lambda:None,_hopWritePromptCommand=lambda:None,thrustCutoffOk=lambda:events.append('cutoff') or True,unlock_steering=lambda:events.append('unlock'),
             yieldToPrompt=lambda:events.append('yield'),reboot=reboot,fixture_wait=wait,route_cancelled=lambda:env['ABORT'],
             geoDistance=lambda *args:1000,mLogError=lambda *args:None)
    class Input:
        @property
        def HASCHAR(self):return bool(keys)
        def GETCHAR(self):return keys.pop(0)
    env['TERMINAL']=NS(INPUT=Input())
    for name in ('hopRouteBudget','hopRouteFuelOk','_hopSurfaceReady','_hopDestinationAllowed',
                 '_hopScheduleSite','hopContinue','hopWaypoint','hopReturn'):
        env[name]=lambda *args,name=name:execute(name,env,*args)
    env['_hopFinishRoute']=lambda economy=False:execute('_hopFinishRoute',env,economy)
    return env,state,updates,events,keys


def check_review_and_reboot():
    env,state,updates,events,keys=fixture()
    execute('phaseHopReview',env)
    assert events[0]=='cutoff' and events[-1]=='yield' and state['hop_route_index']==0
    assert not state['hop_inflight'] and not updates and 2<=env['TIME'].SECONDS<=2.3
    try:execute('hopContinue',env)
    except Reboot:pass
    else:raise AssertionError('no next-leg reboot')
    saved=json.loads(json.dumps(state))
    assert saved['hop_route_index']==0 and saved['hop_route_pending']==1 and saved['phase']=='HOP'
    assert updates==dict(HOP_TARGET_LAT=0,HOP_TARGET_LNG=2)
    execute('_hopApplyPending',env)
    state['hop_route_pending']=1
    execute('_hopApplyPending',env)
    assert state['hop_route_index']==1 and 'hop_route_pending' not in state
    state['phase']='HOP_REVIEW'
    try:execute('hopContinue',env)
    except Reboot:pass
    else:raise AssertionError('no original mission reboot')
    assert state['phase']=='SURFACE_RETURN_SETUP'
    assert updates['RETURN_PE']==53000 and updates['LANDING_FLEXIBLE_SITE']==1
    assert updates['SEQUENCE']==['LAND_ASSIST','SURFACE_RETURN_SETUP']
    print('PASS: settled touchdown yields without input; explicit hopContinue advances one persisted site and after the last restores original return policy without changing mission identity')


def check_budget_and_recovery():
    env,state,updates,events,keys=fixture()
    for available,stage,allowed in ((2000,1300,True),(800,1300,False),(2000,100,False)):
        env['SHIP'].DELTAV.VACUUM=available;env['STAGE'].DELTAV.VACUUM=stage
        assert env['hopRouteFuelOk'](1000)==allowed
    env['SHIP'].DELTAV.VACUUM=800
    execute('hopContinue',env)
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


def check_review_wait_policy():
    review=function_body(HOP,'phaseHopReview')
    assert review.index('SET WARP TO 0.')<review.index('_hopRestoreSavedLimits()')
    assert 'WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.' in review and 'SET BRAKES TO TRUE.' in review
    assert 'TERMINAL:INPUT' not in HOP
    assert not re.search(r'\b(?:ADDALARM|kacEnsureAlarm|orientForSolar|enterSolarCoast)\s*\(',review)
    for fault in ('airborne','body','abort','node','moving','wrong-phase','inactive','roles','terrain','unknown-terrain'):
        env,state,updates,events,keys=fixture()
        if fault=='airborne':env['SHIP'].STATUS='FLYING'
        if fault=='body':env['SHIP'].BODY.NAME='Mun'
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='moving':env['SHIP'].VELOCITY.SURFACE.MAG=1
        if fault=='wrong-phase':state['phase']='HOP'
        if fault=='inactive':state['hop_route_active']=False
        if fault=='roles':env['vesselLandingPrepareRoles']=lambda:False
        if fault in ('terrain','unknown-terrain'):env['landingTerrainGrade']=lambda *args:1 if fault=='terrain' else -1
        execute('hopContinue',env)
        assert not updates and 'hop_route_pending' not in state,fault
    env,state,updates,events,keys=fixture()
    env['SHIP'].VELOCITY.SURFACE.MAG=1
    execute('phaseHopReview',env)
    assert env['TIME'].SECONDS>=10 and events[-1]=='yield' and not updates
    print('PASS: review settles at1x with brakes then yields, never listens for keys or invents alarms/solar; prompt actions reject unsafe surface/body/Abort/nodes/phase/staging/terrain and moving saves time out safely')


def check_waypoint_and_economy_return():
    env,state,updates,events,keys=fixture()
    execute('hopWaypoint',env)
    assert not updates and len(state['hop_route_sites'])==2
    env['selectedWaypoint']=lambda:NS(LATITUDE=1,LONGITUDE=3)
    try:execute('hopWaypoint',env)
    except Reboot:pass
    assert state['hop_route_sites']==[[0,1],[1,3]] and state['hop_route_pending']==1
    assert updates==dict(HOP_TARGET_LAT=1,HOP_TARGET_LNG=3)
    env,state,updates,events,keys=fixture()
    state['hop_route_index']=1
    env['selectedWaypoint']=lambda:NS(LATITUDE=2,LONGITUDE=4)
    try:execute('hopWaypoint',env)
    except Reboot:pass
    assert state['hop_route_sites']==[[0,1],[0,2],[2,4]] and state['hop_route_pending']==2
    env,state,updates,events,keys=fixture()
    try:execute('hopReturn',env)
    except Reboot:pass
    assert not state['hop_route_active'] and state['phase']=='SURFACE_RETURN_SETUP'
    assert updates['SEQUENCE']==['SURFACE_RETURN_SETUP'] and updates['RETURN_PE']==53000
    assert updates['RETURN_KSC_TARGET']==0 and updates['RETURN_PE_TOLERANCE']==1000
    assert updates['RETURN_SEQUENCE']==['ESCAPE','COAST','MCC','AEROBRAKE','DESCENT','DONE']
    assert updates['SURFACE_RETURN_PARKING_ALT']==10000
    assert 'mission_id' not in state and 'hop_route_pending' not in state
    print('PASS: waypoint command replaces/appends only the next leg; explicit hopReturn abandons the route for economy Kerbin return through normal ascent/entry phases without KSC targeting')


def check_local_prompt_script():
    lines=[];deleted=[]
    writer=function_body(HOP,'_hopWritePromptCommand')
    writer=re.sub(r'^\s*LOG (.*) TO wrapperPath\.$',r'fixture_log(\1,wrapperPath).',writer,flags=re.M)
    env=dict(CHAR=chr,EXISTS=lambda path:True,DELETEPATH=deleted.append,
             fixture_log=lambda line,path:lines.append(line))
    ks.run(ks.parse(writer),env)
    source='\n'.join(lines)
    assert deleted==['1:/run/hop.ks'] and not command_entrypoint_errors(source)
    assert source.startswith('PARAMETER action IS "continue".')
    body=function_body(source,'_hopPrompt').replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    # Each call starts a fresh program context: no prior library functions
    # survive the Godspeed prompt. Bootstrap/craft/mission must be reloaded.
    for action in ('continue','waypoint','return','unknown'):
        for configured in (False,True):
            calls=[]
            env=dict(action=action,ABORT=False,SHIP=NS(STATUS='LANDED',THRUST=0,
                     CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
                     RUNPATH=lambda path:calls.append(('run',path)),
                     fixture_settle=lambda:None,bootPreamble=lambda:calls.append(('preamble',)),
                     bootLibLoad=lambda name:calls.append(('load',name)),
                     stateGet=lambda key,default='':{'vehicle':'RO9','mission_id':'minmus_economy_return'}.get(key,default),
                     HOMECONNECTION=NS(ISCONNECTED=False),
                     bootApplyMissionConfig=lambda *args:calls.append(('profile',args)) or configured,
                     hopContinue=lambda:calls.append(('action','continue')),
                     hopWaypoint=lambda:calls.append(('action','waypoint')),
                     hopReturn=lambda:calls.append(('action','return')))
            try:ks.run(without_prints(ks.parse(body)),env)
            except ks.Returned:pass
            assert calls[:4]==[('run','1:/lib/boot_lib'),('preamble',),('load','hop'),('load','craft/RO9')]
            assert calls[4]==('profile',('RO9','minmus_economy_return',False))
            assert calls[5:]==([('action',action)] if configured and action!='unknown' else [])
    review=function_body(HOP,'phaseHopReview')
    assert review.index('_hopWritePromptCommand()')<review.rindex('yieldToPrompt()')
    assert '"1:/run/hop"' in review and 'CHAR(34)' in review
    print('PASS: review writes a wrapped local script before yielding; printed RUNPATH actions start fresh offline contexts, reload cached hop/craft/profile, refuse missing settings and never call old interpreter function pointers')


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
    assert '"hop","landing_main","landing_coast","landing_brake","return_setup"' in conditional
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
    state['hop_route_index']=1
    try:execute('hopContinue',env)
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
    check_review_wait_policy()
    check_waypoint_and_economy_return()
    check_local_prompt_script()
    check_command_and_offline_band()
    check_route_command_execution()
    check_limits_and_finish()
