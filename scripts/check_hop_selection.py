"""Actual surface recovery/menu/selection and disk failure branches, not kOS VM."""
import json
from types import SimpleNamespace as NS

import check_minmus_polar_hops as route
from check_codebase import ROOT, function_body, command_entrypoint_errors
from check_runtime_contracts import KString, run
from check_state_collections import collection, Store

hop = route.hop


def fixture():
    env,state,updates,events,alarms=route.fixture()
    state.update(vehicle='RO9',phase='PRELAUNCH')
    env.update(siteNumber=3,bootPreamble=lambda:None,bootLibLoad=lambda *_:None,
               bootApplyMissionConfig=lambda *_:True,HOMECONNECTION=NS(ISCONNECTED=True),
               UNCHAR=ord,EXISTS=lambda _:False,RUNPATH=lambda *_:None)
    env['_hopMenuSafe']=lambda:hop.ks.call('_hopMenuSafe',env)
    env['bootPruneLandedHopCache']=lambda:run(function_body((ROOT/'lib/boot_lib.ks').read_text(),'bootPruneLandedHopCache'),dict(env))
    env['hopChooseSite']=lambda default:hop.execute('hopChooseSite',env,default)
    return env,state,updates,events,alarms


def command(env):
    source=function_body((ROOT/'cmd/hopnext.ks').read_text(),'_cmdHopnext')
    source=source.replace('RUNPATH("1:/lib/boot_lib").','')
    try:hop.ks.run(hop.without_prints(hop.ks.parse(source)),env)
    except hop.ks.Returned:pass


def check_gamma_and_original_return():
    for active in (False,True):
        env,state,updates,events,alarms=fixture()
        if active:env['hopRoutePrepare']();updates.clear()
        command(env)
        assert state['phase']=='HOP' and state['hop_route_pending']==2
        assert state['hop_route_index']==0 and state['mission_id']=='minmus_polar_hops_return'
        assert [updates['HOP_TARGET_LAT'],updates['HOP_TARGET_LNG']]==[-1.554,2.780]
        assert env['SURFACE_RETURN_ORBIT']['AP']==659734 and env['RETURN_PE']==53000
        assert 'SURFACE_RETURN_SETUP' in state['hop_route_restore']['SEQUENCE']
        assert not any(event=='reboot' for event in events) and not alarms
        state['phase']='HOP_AUTO_REVIEW';env['siteNumber']=0
        command(env)
        assert state['phase']=='SURFACE_RETURN_SETUP' and not state['hop_route_active']
        assert env['SURFACE_RETURN_ORBIT']['AP']==659734 and env['RETURN_PE']==53000
    assert not command_entrypoint_errors((ROOT/'cmd/hopnext.ks').read_text())
    print('PASS: Gamma skips Beta from saved or lost Alpha checkpoint without ignition/reboot/completion changes; configured final orbit and53km return survive selection and early route exit')


def check_selection_guards():
    for fault in ('abort','node','moving','physical','pilot','throttle','airborne','atmosphere',
                  'body','away','roles','fuel','terrain','negative-terrain','number','fraction','profile'):
        env,state,updates,events,alarms=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='moving':env['SHIP'].VELOCITY.SURFACE.MAG=1
        if fault=='physical':env['SHIP'].THRUST=1
        if fault=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='throttle':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if fault=='airborne':env['SHIP'].STATUS='FLYING'
        if fault=='atmosphere':env['SHIP'].BODY.ATM.EXISTS=True
        if fault=='body':env['SHIP'].BODY.NAME='Mun'
        if fault=='away':env['SHIP'].LATITUDE+=1
        if fault=='roles':env['vesselLandingPrepareRoles']=lambda:False
        if fault=='fuel':env['STAGE'].DELTAV.VACUUM=1
        if fault=='terrain':env['landingTerrainGrade']=lambda *_:1
        if fault=='negative-terrain':env['landingTerrainGrade']=lambda *_:-1
        if fault=='number':env['siteNumber']=17
        if fault=='fraction':env['siteNumber']=2.5
        if fault=='profile':env['bootApplyMissionConfig']=lambda *_:False
        command(env)
        assert 'hop_route_pending' not in state,fault
        assert 'HOP_TARGET_LAT' not in updates,fault
    print('PASS: recovery and numbered selection preserve body/site/attitude-control/staging/terrain/fuel/node/Abort/profile guards; invalid site indices cannot launch')


def menu(env,keys):
    queue=list(keys)
    class Input:
        HASCHAR=property(lambda self:bool(queue))
        def GETCHAR(self):return queue.pop(0)
    env['TERMINAL'].INPUT=Input()
    return env['hopChooseSite'](2)


def check_menu_clock_and_cancellation():
    for keys,expected in (('3\r',3),('99\r3\r',3),('2\b3\r',3),('h',-1),('R',0),('\r',2),('',2)):
        for kac in (True,False):
            env,state,updates,events,alarms=fixture();env['hopRoutePrepare']()
            env['ADDONS'].KAC.AVAILABLE=kac
            assert menu(env,keys)==expected,(keys,kac)
            assert not alarms and 'hop_route_pending' not in state
            if not keys:assert 30<=env['TIME'].SECONDS<30.3
    env,state,updates,events,alarms=fixture();env['hopRoutePrepare']()
    state['hop_route_sites']=hop.Items(state['hop_route_sites']*4)
    assert menu(env,'16\r')==16 and not alarms
    for fault in ('abort','node','body','moving','throttle','physical'):
        env,state,updates,events,alarms=fixture();env['hopRoutePrepare']()
        wait=env['fixture_wait']
        def interrupt(seconds):
            wait(seconds)
            if fault=='abort':env['ABORT']=True
            if fault=='node':env['HASNODE']=True
            if fault=='body':env['SHIP'].BODY.NAME='Mun'
            if fault=='moving':env['SHIP'].VELOCITY.SURFACE.MAG=1
            if fault=='throttle':env['SHIP'].CONTROL.MAINTHROTTLE=.1
            if fault=='physical':env['SHIP'].THRUST=1
        env['fixture_wait']=interrupt
        assert menu(env,'')==-1 and not alarms and env['TIME'].SECONDS<1
    print('PASS: bounded numbered menu/backspace/retry/hold/return/default and no-KAC clock work; faults cancel and remove the owned alarm without mutating pending legs')


def check_timed_stop_reaches_real_menu():
    env,state,updates,events,alarms=fixture()
    env['hopRoutePrepare']();state['phase']='HOP_AUTO_REVIEW'
    route.rebooting(env['phaseHopAutoReview'])
    assert 632<=env['TIME'].SECONDS<633 and not alarms
    assert state['phase']=='HOP' and state['hop_route_pending']==1
    assert len([event for event in events if isinstance(event,tuple) and event[0]=='science'])==1
    assert len([event for event in events if isinstance(event,tuple) and event[0]=='alarm'])==2
    phase=function_body(hop.HOP,'phaseHop')
    assert phase.index('IF HASNODE OR (SHIP:STATUS')<phase.index('_hopApplyPending()')
    assert phase.index('IF ABORT OR HASNODE OR SHIP:VELOCITY')<phase.index('LOCK THROTTLE TO hopThrottle')
    print('PASS: actual600s stop enters actual30s KAC menu then selects the next hop; standalone HOP checks nodes/motion before pending progress and rechecks before ignition')


def check_cold_boot_and_sequence():
    boot=function_body((ROOT/'lib/boot_lib.ks').read_text(),'bootEnsureInitialPhase')
    boot=boot.replace('phase:CONTAINS("MAIN")','containsMain(phase)')
    boot=boot.replace('FROM { LOCAL i IS 0. } UNTIL i >= seq:LENGTH STEP { SET i TO i + 1. } DO {',
                      'FOR i IN indices {')
    for phase,active,status,body,route_enabled,expected in (
            ('',False,'LANDED','Minmus',True,'HOP_ROUTE_SETUP'),
            ('PRELAUNCH',False,'LANDED','Minmus',True,'HOP_ROUTE_SETUP'),
            ('LAUNCH',True,'LANDED','Minmus',True,'HOP_AUTO_REVIEW'),
            ('',False,'LANDED','Kerbin',True,'PRELAUNCH'),
            ('PRELAUNCH',False,'ORBITING','Minmus',True,'PRELAUNCH'),
            ('PRELAUNCH',False,'LANDED','Minmus',False,'PRELAUNCH')):
        state={'phase':KString(phase),'hop_route_active':active}
        env=dict(seq=hop.Items(['PRELAUNCH','HOP_ROUTE_SETUP'] if route_enabled else ['PRELAUNCH','LAND_ASSIST']),
                 TARGET_=KString('Minmus'),SHIP=NS(STATUS=status,BODY=NS(NAME=KString(body))),
                 stateGet=lambda key,default='':state.get(key,default),
                 stateSet=lambda key,value:state.update({key:KString(value)}),mLogWarn=lambda *_:None,
                 containsMain=lambda value:'MAIN' in value,indices=range(2))
        assert run(boot,env)==expected,(phase,active,status,body)
    env['SHIP'].BODY.NAME=KString('Minmus')
    state.update(phase=KString('PRELAUNCH'),hop_route_active=True)
    env['seq']=hop.Items(['HOP','LAND_ASSIST','HOP_AUTO_REVIEW'])
    assert run(boot,env)=='HOP_AUTO_REVIEW'
    config=(ROOT/'lib/config.ks').read_text()
    for seq,expected in ((['HOP','LAND_ASSIST','HOP_AUTO_REVIEW'],['HOP','LAND_ASSIST','HOP_AUTO_REVIEW']),
                         (['LAUNCH','PARK'],['PRELAUNCH','LAUNCH','PARK']),
                         (['PRELAUNCH','LAUNCH','PARK'],['PRELAUNCH','LAUNCH','PARK'])):
        env=dict(seq=hop.Items(seq),LIST=lambda *xs:hop.Items(xs))
        env['phaseNeedsPrelaunch']=lambda phase:run(function_body(config,'phaseNeedsPrelaunch'),dict(phaseName=phase))
        assert run(function_body(config,'phaseSequenceEnsurePrelaunch'),env)==expected
    print('PASS: lost/legacy departure state on target surface routes through guarded hop setup; active route recovers review; airborne/other-body/ordinary missions and normal LAUNCH preflight retain their semantics')


def check_failed_state_write_preserves_checkpoint():
    source=function_body((ROOT/'lib/state.ks').read_text(),'_flush').replace('SHUTDOWN.','shutdown().')
    class Stopped(Exception):pass
    for room in (True,False):
        old=dict(phase='HOP_ROUTE_SETUP',boot_count=18,launch_time=3268520,
                 hop_route_sites=[[-1.08,1.365],[-1.554,2.78]])
        current=dict(old,phase='HOP_AUTO_REVIEW')
        disk=[json.dumps(old)];events=[]
        def write(value,path):
            if room:disk[0]=json.dumps(value)
            return None  # Native SaveFile's failed-write return must need no suffix.
        def stopped():raise Stopped()
        env=dict(_cache=collection(current),STATE_PATH='1:/run/state.json',WRITEJSON=write,
                 EXISTS=lambda _:True,READJSON=lambda _:collection(json.loads(disk[0])),
                 SHIP=NS(CONTROL=NS(MAINTHROTTLE=.4,PILOTMAINTHROTTLE=.2)),WARP=4,
                 fixture_lock=lambda text:events.append(text),shutdown=stopped,CORE=NS(VOLUME=NS(FREESPACE=151)))
        stopped_safely=False
        try:hop.ks.run(hop.without_prints(hop.ks.parse(source)),env)
        except Stopped:stopped_safely=True
        assert stopped_safely is (not room)
        assert json.loads(disk[0])==(current if room else old)
        if not room:
            assert env['SHIP'].CONTROL.MAINTHROTTLE==env['SHIP'].CONTROL.PILOTMAINTHROTTLE==env['WARP']==0
            assert events==['LOCK THROTTLE TO 0']
    assert 'DELETEPATH' not in source
    print('PASS: actual flush source never deletes the previous state, verifies the replacement and stops with throttle/warp zero on failed space-limited writes, including native-null returns')


def check_real_reload_commit_and_pending_upgrade():
    env,state,updates,events,alarms=fixture()
    store=Store(state);store.bind(env)
    # Substitute only serialization, not the handoff: all keys use the same
    # generic writer, with no special phase/band mutation in the reboot stub.
    def persist(key,value):
        store.cache[key]=collection(value);store.flush()
    env['stateSet']=persist
    env['stateSaveReloadState']=lambda *args:hop.ks.call('stateSaveReloadState',env,*args)
    command(env)
    store.reboot()
    assert store.get('phase')=='HOP' and store.get('hop_route_pending')==2
    assert store.get('reload_next_phase')=='HOP' and store.get('hop_route_index')==0
    assert store.get('mission_id')=='minmus_polar_hops_return'
    env,state,updates,events,alarms=fixture();env['hopRoutePrepare']()
    state.update(phase='HOP_AUTO_REVIEW',hop_route_pending=2)
    updates.clear()
    route.rebooting(env['phaseHopAutoReview'])
    assert state['phase']=='HOP' and state['hop_route_pending']==2 and state['hop_route_index']==0
    assert updates['HOP_TARGET_LAT']==-1.554 and not alarms and env['TIME'].SECONDS==0
    print('PASS: actual reload helper durably changes boot phase to HOP through JSON, without a fake phase-setting stub; upgrading the native stuck-review/Gamma checkpoint preserves the explicit pending site')


def check_landed_disk_recovery():
    for safe in (True,False):
        env,state,updates,events,alarms=fixture();env['hopRoutePrepare']()
        if not safe:env['SHIP'].STATUS='FLYING'
        files={'1:/run/state.json':'checkpoint','1:/run/mission_overrides.ks':'Gamma',
               '0:/lib/boot_lib.ks':'source','1:/lib/boot_lib.ksm':'cached'}
        for lib in ('landing_main','landing_brake','landing_coast','landing_terminal'):
            files['0:/lib/'+lib+'.ks']='source';files['1:/lib/'+lib+'.ksm']='cached'
        deleted=[]
        env.update(EXISTS=lambda path:path in files,READJSON=lambda _:route.Lex(state),
                   DELETEPATH=lambda path:deleted.append(path) or files.pop(path),
                   RUNPATH=lambda path:events.append(('run',path)),
                   bootPreamble=lambda:events.append(('preamble',len(deleted))))
        command(env)
        assert len(deleted)==(4 if safe else 0)
        assert files['1:/run/state.json']=='checkpoint' and files['1:/run/mission_overrides.ks']=='Gamma'
        if safe:
            assert ('preamble',4) in events and ('run','0:/lib/boot_lib.ks') in events
            assert state['hop_route_pending']==2
    print('PASS: linked settled-surface recovery frees only four replaceable descent caches before loading libraries; state/overrides survive, and an airborne craft cannot prune or select a hop')


if __name__=='__main__':
    check_gamma_and_original_return()
    check_selection_guards()
    check_menu_clock_and_cancellation()
    check_timed_stop_reaches_real_menu()
    check_cold_boot_and_sequence()
    check_failed_state_write_preserves_checkpoint()
    check_real_reload_commit_and_pending_upgrade()
    check_landed_disk_recovery()
