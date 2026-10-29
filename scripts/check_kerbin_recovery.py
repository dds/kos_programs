"""Live recovery inspection, setup and SOI handoff; no native flight runner."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_surface_return import defaults, emit_profile, read_settings

COMMAND=(ROOT/'cmd/kerbinrecover.ks').read_text()
SETUP=(ROOT/'lib/return_setup.ks').read_text()
MCC=(ROOT/'lib/maneuver_mcc.ks').read_text()


class Lex(dict):
    HASKEY=dict.__contains__


class Sequence(list):
    CONTAINS=list.__contains__


def execute(source,env):
    source=re.sub(r'PARAMETER [^.]+\.', '',source) # Arguments supplied in env.
    def strip(nodes):
        return [(text,strip(yes),strip(no)) for text,yes,no in nodes if not text.startswith('PRINT ')]
    try:ks.run(strip(ks.parse(source)),env)
    except ks.Returned as result:return result.value


def fixture():
    kerbin=NS(NAME='Kerbin',RADIUS=600000,MU=3.5316e12)
    patch=NS(BODY=kerbin,PERIAPSIS=9895530,APOAPSIS=52446066,
             INCLINATION=54.8210681912873,LAN=82.9317499876754,
             ARGUMENTOFPERIAPSIS=21.1403178180668,ECCENTRICITY=.67,HASNEXTPATCH=False)
    native=NS(BODY=NS(NAME='Minmus'),HASNEXTPATCH=True,NEXTPATCH=patch)
    saved={'phase':'CAPTURE','vehicle':'RO9','mission_id':'minmus_economy_return'}
    env=defaults()|dict(HASNODE=False,ABORT=False,TIME=NS(SECONDS=1000),
        SHIP=NS(BODY=native.BODY,ORBIT=native,STATUS='ESCAPING',THRUST=0,
                DELTAV=NS(VACUUM=2261),CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)),
        STAGE=NS(NUMBER=3,DELTAV=NS(VACUUM=595)),BODY=native.BODY,
        LEXICON=lambda *xs:Lex(zip(xs[::2],xs[1::2])),SQRT=math.sqrt,
        stateGet=saved.get,stateSet=lambda key,value:saved.update({key:value}),
        LIST=lambda *xs:list(xs),HOMECONNECTION=NS(ISCONNECTED=True),
        CORE=NS(PART=NS(DECOUPLEDIN=0)))
    env['SHIP'].PARTSTAGGED=lambda tag:[NS(DECOUPLEDIN=0)] if tag=='descent_chutes' else []
    env['returnKerbinPatch']=lambda:execute(function_body(SETUP,'returnKerbinPatch'),env)
    return env,saved,patch


def check_live_snapshot():
    env,saved,patch=fixture();original=dict(saved)
    snapshot=lambda:execute(function_body(COMMAND,'_kerbinRecoverySnapshot'),env)
    first=snapshot()
    assert first['FOUND'] and not first['CURRENT']
    assert [first[key] for key in ('PE','AP','INC','LAN','AOP')]==[
        patch.PERIAPSIS,patch.APOAPSIS,patch.INCLINATION,patch.LAN,patch.ARGUMENTOFPERIAPSIS]
    assert abs(first['IDEAL_DV']-108.06308)<.00001
    assert [first[key] for key in ('AVAILABLE_DV','ACTIVE_DV','STAGE')]==[2261,595,3]
    # Change both the orbit and hardware between invocations, then transition
    # to the current Kerbin patch. No pasted numbers may remain in the probe.
    patch.PERIAPSIS=3200000;patch.APOAPSIS=40000000;patch.INCLINATION=12
    patch.LAN=45;patch.ARGUMENTOFPERIAPSIS=70
    env['SHIP'].DELTAV.VACUUM=1800;env['STAGE'].NUMBER=2;env['STAGE'].DELTAV.VACUUM=900
    env['SHIP'].ORBIT=patch;env['SHIP'].BODY=patch.BODY;env['TIME'].SECONDS=2000
    second=snapshot()
    assert second['CURRENT'] and second['UT']==2000
    assert [second[key] for key in ('PE','AP','INC','LAN','AOP')]==[3200000,40000000,12,45,70]
    assert [second[key] for key in ('AVAILABLE_DV','ACTIVE_DV','STAGE')]==[1800,900,2]
    assert second['IDEAL_DV']!=first['IDEAL_DV'] and saved==original
    for bad in ('hyperbolic','negative-radius','bad-apo','nan'):
        patch.ECCENTRICITY=1.2 if bad=='hyperbolic' else .5
        patch.PERIAPSIS=-700000 if bad=='negative-radius' else 3200000
        patch.APOAPSIS=10000 if bad=='bad-apo' else math.nan if bad=='nan' else 40000000
        assert snapshot()['IDEAL_DV']==-1,bad
    env['HASNODE']=True
    assert not snapshot()['FOUND']
    env['HASNODE']=False;patch.BODY=NS(NAME='Sun')
    assert not snapshot()['FOUND']
    patch.HASNEXTPATCH=True;patch.NEXTPATCH=patch
    assert not snapshot()['FOUND'] # Bounded even on a malformed patch cycle.
    assert all(str(value) not in COMMAND for value in (9895530,52446066,54.8210681912873))
    print('PASS: native Minmus exit/current Kerbin snapshots update all elements and stage fuel live; independent108.06m/s estimate, invalid conics, pending nodes and bounded missing/cyclic patch chains checked')


def check_command_and_profile():
    source=function_body(COMMAND,'_cmdKerbinrecover')
    source=re.sub(r'RUN(?:ONCE)?PATH\([^\n]+\)\.', 'fixture_load().',source)
    source=source.replace('diagnosticArchiveLine(', 'mLog(')
    source=source.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.', 'fixture_settle().')
    for action in ('check','apply','invalid','offline','no-patch','bad-report'):
        env,saved,_=fixture();original=dict(saved);calls=[]
        env.update(action='check' if action in ('offline','no-patch','bad-report') else action,
            fixture_load=lambda:None,bootPreamble=lambda:None,bootLibLoad=lambda *_:None,
            fixture_settle=lambda:None,_kerbinRecoverySnapshot=lambda:execute(
                function_body(COMMAND,'_kerbinRecoverySnapshot'),env),
            diagnosticArchiveOpen=lambda _:Lex(READY=True),
            diagnosticArchiveClose=lambda *args:action!='bad-report',
            _kerbinRecoveryStageFloor=lambda:execute(function_body(COMMAND,'_kerbinRecoveryStageFloor'),env),
            phaseReturnSetup=lambda phase:calls.append(phase))
        if action=='offline':env['HOMECONNECTION'].ISCONNECTED=False
        if action=='no-patch':env['HASNODE']=True
        execute(source,env)
        assert saved==original
        assert calls==(['MCC'] if action=='apply' else []),action
        if action=='apply':
            env['targetPe']=env['RETURN_PE']
            home=read_settings(emit_profile('phaseReturnSetup',env),{})
            assert home['SEQUENCE']==['MCC','RETURN_TRIM','AEROBRAKE','DESCENT','DONE']
            assert home['CAPTURE_PE']==home['REENTRY_PE']==home['AEROBRAKE_PE']==53000
            assert home['CAPTURE_INC']==-1 and home['RETURN_TRIM_PE_MIN']==52000
            assert home['MCC_RETURN_AT_APOAPSIS']==1
            assert home['MCC_RETURN_DV_CAP']==-1 and home['MCC_RETURN_RESERVE_DV']==50
            assert home['BURN_STAGE_LIMIT']==1
            assert home['RETURN_TRIM_PE_MAX']==54000 and home['RETURN_TRIM_DV_CAP']==20
            assert home['TARGET_LOCK']==home['AEROBRAKE_TARGETING']==1
            assert [home[key] for key in ('TARGET_LAT','TARGET_LNG')]==[-.0972,-74.5577]
            assert home['DESCENT_DECOUPLE_ALT']==6000 and home['AEROBRAKE_ARM_CHUTES']==1
    assert 'diagnosticArchiveOpen("kerbinrecover")' in COMMAND
    assert 'diagnosticArchiveClose(reportState,"KERBIN RECOVERY")' in COMMAND
    print('PASS: check/invalid/offline/unverified captures change no mission; apply reuses shared serialization for52-54km entry, plane preservation, optional KSC trim and late separation without ESCAPE')


def check_large_recovery_budget_and_staging():
    from check_runtime_contracts import KList
    shared=(ROOT/'lib/return_mcc_config.ks').read_text()
    default=read_settings(shared,{},'GLOBAL')
    assert default['MCC_RETURN_DV_CAP']==150 and default['MCC_RETURN_RESERVE_DV']==50
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for root in ('return_setup','maneuver_mcc'):
        assert 'return_mcc_config' in closure([root],deps)
    # Current native craft:2863.2215x2863.3144km,159.5065m/s onstage2,
    # 813.4343m/s total. Independent vis-viva validates a cross-stage burn.
    mu,radius=3.5316e12,600000
    rp,ra=radius+2863221.52404498,radius+2863314.35046328
    required=math.sqrt(mu*(2/ra-2/(rp+ra)))-math.sqrt(mu*(2/ra-2/(ra+radius+53000)))
    assert abs(required-441.0067697)<1e-6
    budget_env=dict(MCC_RETURN_DV_CAP=-1,MCC_RETURN_RESERVE_DV=50,
                    SHIP=NS(DELTAV=NS(VACUUM=813.434265136719)))
    budget=lambda:execute(function_body(MCC,'_mccReturnBudget'),budget_env)
    assert 150<required<budget() and required>159.506530761719
    budget_env['SHIP'].DELTAV.VACUUM-=required
    assert abs(budget()-(813.434265136719-required-50))<1e-7
    # Execute the existing stage recovery owner, not a replacement stager.
    burn=(ROOT/'lib/maneuver.ks').read_text()
    source=function_body(burn,'_burnRecoverThrust').replace('_burnTraceAdd(', 'mLog(')
    for mode in ('powered','normal','delayed','protected','abort'):
        env,saved,_=fixture();events=[]
        current=NS(NAME='lander',STAGE=2,DECOUPLEDIN=1,IGNITION=True,
                   FLAMEOUT=mode!='powered',AVAILABLETHRUST=10 if mode=='powered' else 0)
        returning=NS(NAME='return',STAGE=1,DECOUPLEDIN=0,IGNITION=False,
                     FLAMEOUT=False,AVAILABLETHRUST=0,UID='return-engine')
        forbidden=NS(NAME='payload',STAGE=0,DECOUPLEDIN=-1,IGNITION=False,
                     FLAMEOUT=False,AVAILABLETHRUST=0,UID='payload-engine')
        separator=NS(TAG='return_decoupler',STAGE=1,ISDECOUPLED=False)
        engines=[current,returning,forbidden]
        env['SHIP'].ENGINES=engines
        env['STAGE']=NS(NUMBER=2,READY=True)
        env['RETURN_DESCENT_CHUTES_TAG']='descent_chutes'
        floor=execute(function_body(COMMAND,'_kerbinRecoveryStageFloor'),env)
        assert floor==1
        nd=NS(DELTAV=NS(MAG=300),TIME=1100)
        env.update(nd=nd,trace=None,ABORT=mode=='abort',BURN_STAGE_LIMIT=2 if mode=='protected' else floor,
                   BURN_STAGE_TIMEOUT=10,BURN_STAGE_MAX_EVENTS=4,BURN_STAGE_SETTLE=.5,
                   BURN_STAGE_MANUAL_WAIT=.2,LIST=lambda *xs:KList(xs))
        ignition_due=[None]
        def sma():return sum(e.AVAILABLETHRUST for e in engines if e.IGNITION and not e.FLAMEOUT)
        def wait(dt):
            env['TIME'].SECONDS+=dt
            if ignition_due[0] is not None and env['TIME'].SECONDS>=ignition_due[0]:
                returning.FLAMEOUT=False;returning.AVAILABLETHRUST=20
        def stage_event():
            assert env['STAGE'].NUMBER==2 and floor==1
            env['STAGE'].NUMBER=1;separator.ISDECOUPLED=True
            engines.remove(current);returning.IGNITION=True
            returning.FLAMEOUT=True
            ignition_due[0]=env['TIME'].SECONDS+(2 if mode=='delayed' else 0)
            events.append('return_decoupler')
        env.update(_sma=sma,fixture_wait=wait,stage_event=stage_event)
        result=execute(source,env)
        assert bool(result)==(mode in ('powered','normal','delayed')),mode
        assert events==(['return_decoupler'] if mode in ('normal','delayed') else []),mode
        assert not forbidden.IGNITION and env['CORE'].PART.DECOUPLEDIN==0
        assert nd.DELTAV.MAG==300 # same node/progress, never reset on separation
    # A parachute on a lower section raises the floor instead of discarding
    # it to reach another engine; a core in that section does the same.
    env,_,_=fixture();env['RETURN_DESCENT_CHUTES_TAG']='descent_chutes'
    env['SHIP'].PARTSTAGGED=lambda _:[NS(DECOUPLEDIN=1)]
    assert execute(function_body(COMMAND,'_kerbinRecoveryStageFloor'),env)==2
    env['SHIP'].PARTSTAGGED=lambda _:[];env['CORE'].PART.DECOUPLEDIN=2
    assert execute(function_body(COMMAND,'_kerbinRecoveryStageFloor'),env)==3
    # Refresh the actual writer after loading it: old RUNONCEPATH definitions
    # at a held MCC prompt must not omit the newly serialized policy.
    owner=function_body(COMMAND,'_cmdKerbinrecover')
    assert owner.index('bootLibLoad("return_mcc_config")')<owner.index('RUNPATH("0:/lib/return_setup.ks")')
    assert owner.index('RUNPATH("0:/lib/return_setup.ks")')<owner.index('SET MCC_RETURN_DV_CAP TO -1')
    print('PASS: native441m/s case is funded across159+654 stages with50m/s retained; actual executor keeps fueled stage, separates return_decoupler on depletion, survives delayed ignition and preserves node/CPU/chutes/floor/Abort safeguards')


def check_setup_and_soi_guards():
    setup=function_body(SETUP,'phaseReturnSetup')
    # Stop at archive entry: a passing guard must reach it, while rejection
    # must yield before any profile/identity edits. Full writer has its own
    # fresh-boot fixtures, shared with unchanged moon-return callers.
    guard=setup[:setup.index('    IF HOMECONNECTION:ISCONNECTED')]
    for failure in ('none','abort','node','no-patch','landed','sequence','interrupted','thrust','raw','pilot','unknown-phase'):
        env,saved,_=fixture();original=dict(saved);yielded=[]
        env.update(startPhase='MCC',RETURN_SEQUENCE=Sequence(['MCC','RETURN_TRIM','AEROBRAKE','DESCENT','DONE']),
                   yieldToPrompt=lambda:yielded.append(True))
        if failure=='abort':env['ABORT']=True
        if failure=='node':env['HASNODE']=True
        if failure=='no-patch':env['SHIP'].ORBIT.HASNEXTPATCH=False
        if failure=='landed':env['SHIP'].STATUS='LANDED'
        if failure=='sequence':env['RETURN_SEQUENCE']=Sequence(['AEROBRAKE','DONE'])
        if failure=='interrupted':saved.update(burn_pending='true',burn_started='true');original=dict(saved)
        if failure=='thrust':env['SHIP'].THRUST=1
        if failure=='raw':env['SHIP'].CONTROL.MAINTHROTTLE=.1
        if failure=='pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE=.1
        if failure=='unknown-phase':env['startPhase']='DESCENT'
        execute(guard,env)
        assert bool(yielded)==(failure!='none'),failure
        assert saved==original
    assert 'PARAMETER startPhase IS "ESCAPE".' in setup
    assert 'stateSet("phase", startPhase).' in setup
    assert 'stateSet("lib_band", bootLibBandForPhase(startPhase,startPhase)).' in setup
    phase=function_body(MCC,'_mccReturn')
    until_plan=phase[:phase.index('    // Three finite-burn corrections')]
    until_plan=until_plan.replace('WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    for arrival in ('success','aborted','wrong-body'):
        env,saved,patch=fixture();held=[];order=[]
        def wait(_):
            order.append('soi')
            if arrival!='wrong-body':env['SHIP'].BODY=patch.BODY
            if arrival=='aborted':env['ABORT']=True
        env.update(target=patch.BODY,targetPe=53000,maneuverBurnInterrupted=lambda:False,
            _getTargetPatch=lambda *_:patch,waitForSOI=wait,
            fixture_settle=lambda:order.append('settled'),_mccReturnHold=held.append,
            _mccReturnApoapsisCoast=lambda *_:True)
        execute(until_plan,env)
        assert held==([] if arrival=='success' else ['Kerbin-soi-wait-interrupted'])
        assert order==['soi','settled'] and env['WARP']==0
    print('PASS: recovery guard rechecks live patch/abort/node/interruption/thrust before state edits; original moon ESCAPE default remains, MCC waits for SOI and cannot plan after abort or in the wrong frame')


def check_apoapsis_live_coast():
    coast=function_body(MCC,'_mccReturnApoapsisCoast').replace(
        'WAIT UNTIL KUNIVERSE:TIMEWARP:ISSETTLED.','fixture_settle().')
    for mode in ('normal','no-kac','disabled','safe','inbound','hyperbolic','near-apo','suborbital','inside-atmo',
                 'another-soi','bad-eta','abort','wrong-body','node','early'):
        env,saved,patch=fixture();events=[];held=[]
        env['SHIP'].BODY=patch.BODY;env['SHIP'].ORBIT=patch
        env['SHIP'].STATUS='SUB_ORBITAL' if mode=='suborbital' else 'ORBITING'
        env['SHIP'].ALTITUDE=60000 if mode=='inside-atmo' else 47000000
        patch.BODY.ATM=NS(HEIGHT=70000)
        env['SHIP'].POSITION=1;patch.BODY.POSITION=0
        env['SHIP'].VELOCITY=NS(ORBIT=-1 if mode=='inbound' else 1)
        env.update(target=patch.BODY,targetPe=53000,MCC_RETURN_AT_APOAPSIS=0 if mode=='disabled' else 1,
            VDOT=lambda a,b:a*b,ETA=NS(APOAPSIS=1000),
            _mccAerobrakePatchSafe=lambda *_:mode=='safe',_mccReturnHold=held.append,
            fixture_settle=lambda:None,DELETEALARM=lambda key:events.append(('delete',key)))
        def alarm(*args):
            events.append(('alarm',args[1]));return '' if mode=='no-kac' else 'owned'
        def solar(*args):
            assert events==[('alarm',1700)] # Wake is installed before pointing.
            events.append(('solar',args[-1]));return 1
        def wait(*args):
            assert args[0] is patch.BODY and args[1]==1700 and args[-2:]==(True,True)
            events.append(('clock',args[1]))
            env['TIME'].SECONDS=1600 if mode=='early' else args[1]
            if mode=='abort':env['ABORT']=True
            if mode=='wrong-body':env['SHIP'].BODY=NS(NAME='Minmus')
            if mode=='node':env['HASNODE']=True
        env.update(kacEnsureAlarm=alarm,enterSolarCoast=solar,waitUntilOrSOI=wait)
        if mode=='hyperbolic':patch.ECCENTRICITY=1.1
        if mode=='near-apo':env['ETA'].APOAPSIS=200
        if mode=='another-soi':patch.HASNEXTPATCH=True
        if mode=='bad-eta':env['ETA'].APOAPSIS=math.nan
        result=execute(coast,env)
        skipped=mode in ('disabled','safe','inbound','hyperbolic','near-apo','suborbital','inside-atmo')
        invalid=mode in ('another-soi','bad-eta')
        interrupted=mode in ('abort','wrong-body','node','early')
        assert bool(result)==(not invalid and not interrupted),mode
        assert bool(held)==(invalid or interrupted),mode
        if skipped or invalid:assert not events
        else:
            assert events[:3]==[('alarm',1700),('solar',1700),('clock',1700)]
            assert ('delete','owned') in events if mode!='no-kac' else len(events)==3
            assert env['WARP']==0
    phase=function_body(MCC,'_mccReturn')
    assert phase.index('_mccReturnApoapsisCoast(target,targetPe)')<phase.index('LOCAL nd IS NODE(')
    print('PASS: opt-in outbound recovery coasts near native apoapsis with alarm before solar and clock fallback, retains budgets, revalidates interruptions and never waits an extra orbit on inbound/hyperbolic/near-apo paths')


if __name__=='__main__':
    check_live_snapshot()
    check_command_and_profile()
    check_large_recovery_budget_and_staging()
    check_setup_and_soi_guards()
    check_apoapsis_live_coast()
