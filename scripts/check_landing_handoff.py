"""Offline landing cache and radio-policy regressions, not a kOS compiler."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_boot_install import fixture as disk_fixture, Text, Items, BOOT
from check_codebase import ROOT, function_body, dependency_tables, closure
from check_runtime_contracts import KList, run

HANDOFF=(ROOT/'lib/landing_handoff.ks').read_text()
RADIO=(ROOT/'lib/landing_radio.ks').read_text()
ks.SOURCES+='\n'+HANDOFF+'\n'+RADIO


class Map(dict):
    HASKEY=dict.__contains__
    LENGTH=property(len)


def cache_fixture(capacity=30000,linked=True):
    env,files,events,state=disk_fixture(linked,HANDOFF)
    def size(path):
        payload=files[str(path)]
        if isinstance(payload,tuple):payload=payload[1]
        return len(payload or '')
    class Volume:
        @property
        def FREESPACE(self):return capacity-sum(size(p) for p in files if p.startswith('1:/'))
    env.update(CORE=NS(VOLUME=Volume()),OPEN=lambda p:NS(SIZE=size(p)),
               LEXICON=lambda *args:Map(zip(args[::2],args[1::2])))
    return env,files,events,state


def check_cache_copy_and_offline_reboot():
    env,files,events,state=cache_fixture()
    files['1:/lib/state.ksm']=('ksm','s'*1000)
    env['BOOT_LIB_RAN'].ADD(Text('state'))
    for name in ('payload_landing','landing_main','landing_coast','landing_brake'):
        files['0:/lib/'+name+'.ks']='x'*2000
    libs=Items(map(Text,('state','payload_landing','landing_main','landing_coast','landing_brake')))
    assert not env['bootLibCacheReady'](libs)
    assert env['bootLibEnsureCached'](libs)
    assert len([e for e in events if e[0]=='compile'])==4
    assert len([e for e in events if e[0]=='copy'])==4
    assert not any(e[0]=='run' for e in events) # Cache != load another band.
    assert files['1:/lib/state.ksm']==('ksm','s'*1000)
    events.clear();env['HOMECONNECTION'].ISCONNECTED=False
    assert env['bootLibEnsureCached'](libs) and not events
    files['1:/lib/landing_brake.ksm']=('ksm','')
    assert not env['bootLibEnsureCached'](libs) and not events
    print('PASS: complete future cache copies without loading code or changing current libraries; offline reboot accepts it and rejects an empty braking file without archive access')


def check_capacity_and_failed_copy():
    for fault in ('capacity','missing-source','archive-only','disconnect','short-copy'):
        env,files,events,state=cache_fixture(capacity=7000 if fault=='capacity' else 30000)
        files['1:/lib/current.ksm']=('ksm','retained-current-program')
        files['1:/lib/landing_main.ksm']=('ksm','old-main')
        files['0:/lib/landing_main.ks']='x'*2000
        files['0:/lib/landing_brake.ks']='x'*2000
        original={k:v for k,v in files.items() if k.startswith('1:/')}
        if fault=='missing-source':files.pop('0:/lib/landing_brake.ks')
        if fault=='archive-only':env['bootLibArchiveOnly']=lambda _:True
        if fault=='disconnect':
            compile_file=env['compile_file']
            def compile_then_drop(src,dest):
                compile_file(src,dest);env['HOMECONNECTION'].ISCONNECTED=False
            env['compile_file']=compile_then_drop
        if fault=='short-copy':
            def short(src,dest):files[str(dest)]=('ksm','truncated')
            env['COPYPATH']=short
        assert not env['bootLibEnsureCached'](Items(map(Text,('landing_main','landing_brake')))),fault
        if fault!='short-copy':assert {k:v for k,v in files.items() if k.startswith('1:/')}==original
        assert files['1:/lib/current.ksm']==original['1:/lib/current.ksm']
    print('PASS: insufficient whole-set capacity, missing/archive-only source and disconnect preserve the local cache; truncated copies cannot authorize a burn, current code is never evicted')


def handoff_fixture():
    env,files,events,state=cache_fixture()
    deps,phases,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    deps=Map({key:Items(value) for key,value in deps.items()})
    env.update(xferSeq=Items(['LAND_DEORBIT','LAND_ASSIST','SURFACE_RETURN_SETUP']),
               LIBS=Items(),dependencyLibs=lambda:deps,
               bootLibBandForPhase=lambda *args:Text('LANDING'),
               bootLibBandRoots=lambda _:Items(phases['land_assist']),
               missionTypeConditionalRoots=lambda _:Items(['landing_coast','landing_brake','return_setup']),
               missionExtraLibs=lambda:Items())
    env['missionAppendUnique']=lambda dest,src:dest.extend(x for x in src if x not in dest)
    resolve=env['bootLibAppendResolved']
    env['bootLibAppendResolved']=lambda dest,name,dependencies:resolve(dest,Text(name),dependencies)
    for name in re.findall(r'(?:LOCAL|GLOBAL) FUNCTION (\w+)',HANDOFF):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    return env,files,events,state


def check_full_closure_and_override():
    env,files,events,state=handoff_fixture()
    libs=env['_landingHandoffLibs']()
    assert {'payload_landing','landing_main','landing_coast','landing_brake','landing_terminal',
            'landing_diagnostics','landing_divert','landing_roles','thrust_cutoff','return_setup'}<=set(libs)
    for name in libs:files['1:/lib/'+name+'.ksm']=('ksm','valid-file')
    assert env['landingHandoffReady']()
    files.pop('1:/lib/landing_brake.ksm')
    assert not env['landingHandoffReady']()
    env['LIBS']=Items(['payload_landing'])
    assert not env['landingHandoffReady']() # A LIBS override cannot omit FSM.
    env['xferSeq']=Items(['TARGETED_DEORBIT','RELEASE_PROBE','DONE'])
    assert env['landingHandoffReady']() # No powered landing of this craft.
    assert not events and not state
    print('PASS: handoff resolves the entire actual boot closure plus both tracks and return provider; one missing brake rejects, incomplete LIBS cannot bypass, payload-only releases are unchanged')


def check_deorbit_admission_and_track_retention():
    source=function_body((ROOT/'lib/deorbit_burn.ks').read_text(),'executeDeorbitNode')
    prefix=source.split('    IF NOT landingLightNodeAllowed',1)[0]
    prefix=re.sub(r'WAIT UNTIL (.*?)\.(?=\s*\n)',r'UNTIL \1 { WAIT 0.02. }',prefix,flags=re.S)
    events=[]
    env=dict(nd=NS(DELTAV=NS(MAG=10),TIME=1000),TIME=NS(SECONDS=0),ABORT=False,
             SHIP=NS(MASS=1,CONTROL=NS(PILOTMAINTHROTTLE=.5)),
             KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
             vesselLandingPrepareRoles=lambda:True,landingHandoffReady=lambda *_:False,
             vesselLandingCleanup=lambda:events.append('cutoff'),fixture_lock=lambda s:events.append(s))
    assert run(prefix,env) is False
    assert events==['LOCK THROTTLE TO 0','cutoff'] and env['SHIP'].CONTROL.PILOTMAINTHROTTLE==0
    env['HASNODE']=True
    def prepare(*args):env['TIME'].SECONDS=999;return True
    env['landingHandoffReady']=prepare
    assert run(prefix,env) is False # Compilation must not expire the node.
    assert source.count('landingHandoffReady(')==2
    assert source.index('landingHandoffReady(TRUE)')<source.index('vesselStageForLanding(')
    assert source.index('landingHandoffReady()')<source.index('stateSet("deorbit_burn_started"')
    main=(ROOT/'lib/landing_main.ks').read_text()
    track=function_body(main,'_landingEnsureStateTrack')
    assert 'DELETEPATH' not in track and '_landingDeleteTrack' not in main
    env,files,events,state=cache_fixture(linked=False)
    files['1:/lib/landing_brake.ksm']=('ksm','SET fixtureBrakeLoaded TO TRUE.')
    env.update(landingActiveTrack='',landingLoadedTracks=Items(),landingAbortFlag=False,
               _landingTrackForState=lambda _:Text('landing_brake'),stateName=Text('BRAKING_BURN'))
    env['run_body'](track)
    assert env['fixtureBrakeLoaded']
    assert env['landingActiveTrack']=='landing_brake' and '1:/lib/landing_brake.ksm' in files
    assert not any(e[0]=='compile' for e in events)
    print('PASS: missing handoff code cuts off before staging/thrust; long-coast gate rechecks before burn marker; cached tracks load offline and remain on disk for a later reboot')


def check_shared_radio_policy():
    from check_landing_light import environment
    env=environment(kerbin_longitude=180)
    env.update(LANDING_REQUIRE_KERBIN=0,LANDING_LIGHT_MODE='ANY',
               LANDING_DIRECT_KERBIN_BODIES=KList(['Mun','Minmus']))
    env['SHIP'].BODY.ORBIT=NS(ECCENTRICITY=.1)
    for name in ('Mun','Minmus'):
        env['SHIP'].BODY.NAME=name
        assert env['landingRequireKerbin']()==1 and env['landingLightActive']()
        assert not env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    env['LANDING_RELAY_BODIES']=KList(['Minmus'])
    env['LANDING_REQUIRE_KERBIN']=1 # Old economy profiles migrate globally.
    assert env['landingRequireKerbin']()==0
    assert env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    env['LANDING_RADIO_MODE']='DIRECT'
    assert env['landingRequireKerbin']()==1
    env['LANDING_RADIO_MODE']='OFFLINE'
    assert env['landingRequireKerbin']()==0
    env['LANDING_RADIO_MODE']='TYPO'
    assert env['landingLightActive']() and not env['landingLightAt'](0,0,env['TIME'].SECONDS)['OK']
    # Committed-diversion policy can still waive radio explicitly. This
    # cannot waive the separate mandatory code-cache gate before deorbit.
    env['LANDING_RADIO_MODE']='DIRECT'
    assert env['landingLightAt'](0,0,env['TIME'].SECONDS,0,0)['OK']
    print('PASS: shared Mun/Minmus AUTO policy rejects far-side sites despite legacy0; per-body relays waive direct view across profiles, DIRECT/OFFLINE overrides are explicit and invalid mode holds; committed diversion waiver remains')


if __name__=='__main__':
    check_cache_copy_and_offline_reboot()
    check_capacity_and_failed_copy()
    check_full_closure_and_override()
    check_deorbit_admission_and_track_retention()
    check_shared_radio_policy()
