"""Exercise boot file contracts with an exact-name fake disk, not a kOS compiler."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_runtime_contracts import KString, KList, run

BOOT=(ROOT/'lib/boot_lib.ks').read_text()
BOOTSTRAP=(ROOT/'boot/boot.ks').read_text()
CONFIG=(ROOT/'lib/config.ks').read_text()

class Text(KString):
    TRIM=property(lambda self:Text(self.strip()))
    def __add__(self,other):return Text(str(self)+str(other))
    def __radd__(self,other):return Text(str(other)+str(self))
    def SUBSTRING(self,start,count=None):return Text(super().SUBSTRING(start,count))
    def SPLIT(self,sep):return Items(map(Text,self.split(sep)))

class Items(KList):
    def CONTAINS(self,value):return value in self

def fixture(linked=True,capacity=200000):
    fixture_source=BOOT+'\n'+CONFIG+'\n'+BOOTSTRAP
    files,events,state={},[],{}
    cwd=[Text('1:/')]
    env=dict(HOMECONNECTION=NS(ISCONNECTED=linked),HAS_LINK=linked,
        EXISTS=lambda path:exists(path),CREATEDIR=lambda path:files.update({str(path):None}),
        COPYPATH=lambda src,dest:copy(src,dest),DELETEPATH=lambda path:files.pop(str(path)),
        PATH=lambda:cwd[0],CD=lambda path:cwd.__setitem__(0,Text(path)),
        LIST=lambda *xs:Items(xs),text=Text,BOOT_LIB_RAN=Items(),BOOT_CACHE_PENDING=False,MAX=max,
        KSM_SKIP=Items(),archiveBootstrapLibs=Items(),
        stateGet=state.get,stateGetNum=state.get,
        stateSet=lambda key,value:state.update({key:value}),stateRemove=lambda key:state.pop(key,None),
        SHIP=NS(STATUS='ORBITING'),BOOT_MANUAL_REQUESTED=False,phaseShouldYield=False,
        MISSION_ID='',MISSION_NAME='',TARGET_='',MISSION_TYPE='',PAYLOADS=Items(),
        applyKnownMissionState=lambda:None,getTarget=lambda *_:env['TARGET_'],
        bootLibResolve=lambda roots:roots,bootLibArchiveOnly=lambda _:False,
        bootLibAddUnique=lambda dest,key:dest.ADD(key) if key not in dest else None,
        yieldToPrompt=lambda:env.update(phaseShouldYield=True))
    def file_size(value):
        if value is None:return 0
        if isinstance(value,tuple):value=value[1]
        return len(value.encode())
    class Volume:
        FREESPACE=property(lambda self:capacity-sum(file_size(value) for path,value in files.items() if path.startswith('1:/')))
    volume=Volume()
    env.update(CORE=NS(VOLUME=volume),OPEN=lambda path:NS(SIZE=file_size(files[str(path)])))
    def exists(path):
        if str(path).startswith('0:/'):assert env['HOMECONNECTION'].ISCONNECTED
        return str(path).replace('/./','/') in files
    def copy(src,dest):
        assert exists(src)
        if str(dest).startswith('1:/'):
            assert volume.FREESPACE+file_size(files.get(str(dest)))>=file_size(files[str(src)])
        events.append(('copy',str(src),str(dest)))
        files[str(dest)]=files[str(src)]
    def compile_file(src,dest):
        assert exists(src)
        assert str(src).startswith('0:/') and str(dest).startswith('0:/')
        events.append(('compile',str(src),str(dest)))
        files[str(dest)]=('ksm',files[str(src)])
    def listing(rows):
        prefix=str(cwd[0]).rstrip('/')+'/'
        for path,value in files.items():
            if path.startswith(prefix) and '/' not in path[len(prefix):]:
                rows.ADD(NS(NAME=Text(path[len(prefix):]),ISFILE=value is not None))
    def running(path):
        assert exists(path),path
        events.append(('run',str(path)))
        payload=files[str(path)]
        if isinstance(payload,tuple):payload=payload[1]
        if 'GLOBAL FUNCTION main' in payload:
            env['loaded_main']=function_body(payload,'main')
        else:run(adapt(payload),env)
    def adapt(source):
        source=re.sub(r'\bPRINT\s+(?:"[^"]*"|[^."])*\.', '',source)
        source=source.replace('COMPILE src TO arKsm.','compile_file(src,arKsm).')
        source=re.sub(r'COMPILE (\w+) TO (\w+)\.',r'compile_file(\1,\2).',source)
        source=re.sub(r'COMPILE ("[^"]+") TO ("[^"]+")\.',r'compile_file(\1,\2).',source)
        source=source.replace('LIST FILES IN items.','listing(items).')
        source=source.replace('DEFINED printStorageStatus','FALSE')
        source=source.replace('DEFINED BOOT_LIB_RAN','defined_boot_registry()')
        source=source.replace('SHUTDOWN.','shutdown().')
        return re.sub(r'"[^"\n]*"',lambda match:'text('+match[0]+')',source)
    env.update(compile_file=compile_file,listing=listing,RUNPATH=running,RUNONCEPATH=running)
    prepared={}
    def invoke(name,*args):
        if name not in prepared:
            body=function_body(fixture_source,name)
            prepared[name]=(re.findall(r'PARAMETER (\w+)',body),ks.compile_nodes(ks.freeze(ks.parse(adapt(body)))))
        params,compiled=prepared[name]
        local=env if name in ('bootApplyMissionConfig','bootLibLoadList','bootCacheNextBand','main') else dict(env)
        local.update(zip(params,args))
        try:ks.execute(compiled,local)
        except ks.Returned as result:return result.value
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',fixture_source):
        env[name]=lambda *args,name=name:invoke(name,*args)
    env['bootLibResolve']=lambda roots:roots
    env['bootLibArchiveOnly']=lambda _:False
    env['run_body']=lambda source:run(adapt(source),env)
    env.setdefault("MISSION_CACHE_NEXT_BAND",0)
    return env,files,events,state


def check_bootstrap_full_disk_fallback_and_missing_exports():
    env,files,events,_=fixture()
    initial='SET BOOT_LIB_RAN TO LIST().\n'
    fresh=initial+'//'+('n'*(19686-len(initial)-2))
    old='SET stale_boot TO TRUE.\n//'+('o'*(18949-25))
    files.update({'0:/lib/boot_lib.ks':fresh,'1:/lib/boot_lib.ksm':old,
                  '1:/run/state.json':'checkpoint','1:/other':''})
    files['1:/other']='x'*(199849-sum(len(value) for path,value in files.items() if path.startswith('1:/')))
    env.pop('BOOT_LIB_RAN')
    assert env['CORE'].VOLUME.FREESPACE==151
    assert env['_syncLib'](Text('boot_lib')) is False
    assert files['1:/lib/boot_lib.ksm']==old
    assert env['_loadLib'](Text('boot_lib')) is True
    assert 'BOOT_LIB_RAN' in env and 'stale_boot' not in env
    assert files['1:/run/state.json']=='checkpoint'
    assert [event[1] for event in events if event[0]=='run']==['0:/lib/boot_lib.ks']
    env,files,events,_=fixture(False);env.pop('BOOT_LIB_RAN')
    class Stopped(Exception):pass
    def stopped():raise Stopped()
    env.update(defined_boot_registry=lambda:'BOOT_LIB_RAN' in env,shutdown=stopped,
               fixture_lock=lambda *_:None,WARP=3)
    env['SHIP'].CONTROL=NS(MAINTHROTTLE=.3,PILOTMAINTHROTTLE=.2)
    guard=BOOTSTRAP.split('IF NOT _loadLib("boot_lib")',1)[1].split('IF DEFINED BOOT_HAS_SURFACE_CACHE_RECOVERY',1)[0]
    guard='IF NOT _loadLib("boot_lib")'+guard
    try:env['run_body'](guard)
    except Stopped:pass
    else:raise AssertionError('missing bootstrap must stop before dereferencing BOOT_LIB_RAN')
    assert 'BOOT_LIB_RAN' not in env and env['SHIP'].CONTROL.MAINTHROTTLE==env['SHIP'].CONTROL.PILOTMAINTHROTTLE==0
    print('PASS: actual bootstrap with151B free preserves old19KB library and executes fresh archive exports; missing offline bootstrap stops with cutoff before registry use, without fabricating initialization or changing state')

def check_legacy_and_compiled_resolution():
    for suffix in ('','.ks','.ksm'):
        env,files,events,_=fixture(False)
        files['1:/craft/RO9'+suffix]=''
        assert env['bootResolveScript'](Text('RO9'),Items([Text('craft')]),False)=='craft/RO9'
        assert env['bootLocalScriptPath'](Text('craft/RO9'))=='1:/craft/RO9'+suffix
        assert not events
    env,files,_,_=fixture(False)
    for suffix in ('','.ks','.ksm'):files['1:/craft/RO9'+suffix]=''
    assert env['bootLocalScriptPath'](Text('craft/RO9'))=='1:/craft/RO9.ksm'
    files['1:/X_SHOT']=''
    assert env['bootResolveScript'](Text('X_SHOT'),Items([Text('craft')]),False)=='./X_SHOT'
    assert env['bootLocalScriptPath'](Text('./X_SHOT'))=='1:/./X_SHOT'
    print('PASS: offline resolver finds deployed bare/source/compiled craft; explicit compiled path wins without accessing archive')

def check_shared_install_and_offline_main():
    env,files,events,state=fixture()
    files['0:/craft/RO9.ks']=(ROOT/'craft/RO9.ks').read_text()
    files['1:/craft/RO9']='old extensionless source'
    profile='SET MISSION_ID TO "minmus_economy_return". SET TARGET_ TO "MINMUS". SET SEQUENCE TO LIST("BPLANE","COAST_1HALF").'
    files['0:/missions/RO9/minmus_economy_return.ks']=profile
    state.update(phase='COAST_1HALF',mission_id='minmus_economy_return')
    env['bootLibLoad'](Text('craft/RO9'))
    assert 'rocketMain(' in env['loaded_main']
    assert env['bootApplyMissionConfig'](Text('RO9'),Text('minmus_economy_return'),True)
    assert files['1:/craft/RO9.ksm'][0]=='ksm'
    assert files['1:/missions/RO9/minmus_economy_return.ksm'][0]=='ksm'
    assert '1:/missions/RO9' in files
    assert len([event for event in events if event[0]=='compile'])==2
    events.clear();env['HOMECONNECTION'].ISCONNECTED=False;env.pop('loaded_main')
    env['bootLibLoad'](Text('craft/RO9'))
    assert env['bootApplyMissionConfig'](Text('RO9'),Text('minmus_economy_return'),False)
    assert 'rocketMain(' in env['loaded_main'] and env['TARGET_']=='MINMUS'
    assert state['phase']=='COAST_1HALF'
    assert all(event[0]=='run' and event[1].startswith('1:/') for event in events)
    print('PASS: craft and static profile compile on archive via shared installer; cold offline reload restores RO9 main and selected profile without phase mutation')


def check_full_hop_disk_and_reserved_cache():
    env,files,events,_=fixture(capacity=200000)
    # Measured native disk at UT4212185: state15,896B, landing_main16,634B,
    # total199,849B. Fake bytecode sizes are explicit, not native compilation.
    files.update({'1:/run/state.json':'s'*15896,'1:/lib/landing_main.ksm':'m'*16634,
                  '1:/other':'x'*(199849-15896-16634),'0:/lib/return_setup.ks':'r'*6896})
    assert env['CORE'].VOLUME.FREESPACE==151
    assert not env['bootLibSync'](Text('return_setup'),4096)
    assert '1:/lib/return_setup.ksm' not in files and files['1:/run/state.json']=='s'*15896
    files['1:/lib/return_setup.ksm']='old'
    assert not env['bootLibSync'](Text('return_setup'),4096)
    assert files['1:/lib/return_setup.ksm']=='old'
    del files['1:/lib/landing_main.ksm']
    assert env['bootLibSync'](Text('return_setup'),4096)
    assert env['CORE'].VOLUME.FREESPACE>=4096 and files['1:/run/state.json']=='s'*15896
    print('PASS: measured151B-free hop disk cannot install6,896B return library; preflight retains checkpoint/old code, then installs after bounded surface cleanup with4KiB state/log headroom')


def check_cache_is_not_executed():
    env,files,events,_=fixture()
    files['0:/lib/core.ks']='SET KEEP_WARP TO 0.'
    files['0:/lib/next.ks']='SET simulated_throttle TO 1.'
    env.update(BOOT_CACHE_PENDING=True,BOOT_CACHE_LIBS=Items([Text('next')]))
    env['bootLibLoadList'](Items([Text('core')]))
    assert env['BOOT_CACHE_PENDING'] and '1:/lib/next.ksm' not in files
    env['SHIP'].STATUS='LANDED'
    env['bootCacheNextBand']()
    assert not env['BOOT_CACHE_PENDING'] and 'simulated_throttle' not in env
    assert '1:/lib/next.ksm' in files
    assert [event[1] for event in events if event[0]=='run']==['1:/lib/core.ksm']
    keep=function_body(BOOT,'bootCleanup').split('LOCAL kr IS',1)[0]+'RETURN kl.'
    env.update(vn='RO9',wl=Items([Text('core')]),missionVehicle='RO9')
    assert 'next' in env['run_body'](keep)
    env['HOMECONNECTION'].ISCONNECTED=False
    events.clear();env['BOOT_CACHE_PENDING']=True
    env['bootLibLoadList'](Items([Text('core')]))
    assert 'simulated_throttle' not in env and all(event[0]=='run' for event in events)
    print('PASS: airborne boot defers future caching until touchdown; next-band files survive cleanup without RUNPATH or leaked handlers/config/throttle, and offline boot never accesses archive')

def check_profile_listing_and_generation():
    env,files,_,_=fixture(False)
    files['1:/missions/RO9']=None
    for name in ('minmus_economy_return.ks','minmus_economy_return.ksm','notes.ks.bak'):
        files['1:/missions/RO9/'+name]=''
    assert env['bootCachedMissionConfigIds'](Text('RO9'))==['minmus_economy_return']
    files['1:/missions/RO9/kerbin_return.ksm']=('ksm','old return')
    path=env['missionProfileBegin'](Text('RO9'),Text('kerbin_return'))
    assert '1:/missions/RO9/kerbin_return.ksm' not in files
    files[str(path)]='SET MISSION_ID TO "kerbin_return". SET TARGET_ TO "KERBIN".'
    assert env['bootApplyMissionConfig'](Text('RO9'),Text('kerbin_return'),False)
    assert env['TARGET_']=='KERBIN'
    print('PASS: cached KSM profiles retain correct IDs without duplicates; fresh onboard profiles invalidate stale bytecode and remain runnable offline as source')

def check_boot_entry_and_missing_main():
    source=(ROOT/'boot/boot.ks').read_text()
    assert 'COPYPATH("0:/" + vehicleScript' not in source
    assert 'bootLibSync(vehicleScript)' in source
    assert source.count('RUNPATH(bootLocalScriptPath(vehicleScript))')==2
    env,_,_,state=fixture(False)
    state['phase']='BPLANE'
    env['main']()
    assert env['BOOT_MANUAL_REQUESTED'] and env['phaseShouldYield'] and state['phase']=='BPLANE'
    print('PASS: bootstrap uses shared compiled installation and explicit local run paths; absent vehicle main cannot pretend to run a mission')

def check_boot_update_install():
    body=function_body((ROOT/'cmd/updateboot.ks').read_text(),'_cmdUpdateBoot')
    for selected in ('boot/boot.ksm','boot/boot_updated.ksm','1:/boot/boot_updated.ksm','/boot/boot_updated.ksm'):
        env,files,events,state=fixture()
        env['CORE']=NS(BOOTFILENAME=Text(selected))
        env['SHIP']=NS(THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
        files['0:/boot/boot.ks']='new bootstrap source'
        files['0:/boot/boot.ksm']=('ksm','tracked VAB release')
        files['0:/boot/boot_update.ksm']=('ksm','previous build')
        selected_path=selected if selected.startswith('1:/') else '1:/'+selected.lstrip('/')
        files[selected_path]=('ksm','previous boot')
        env['run_body'](body)
        assert env['CORE'].BOOTFILENAME!=selected and files[selected_path]==('ksm','previous boot')
        assert files['1:/'+env['CORE'].BOOTFILENAME]==('ksm','new bootstrap source')
        assert files['0:/boot/boot.ksm']==('ksm','tracked VAB release')
        assert not state  # Installation never resets or starts a mission.
    for failure in ('offline','thrust','copy'):
        env,files,events,_=fixture(failure!='offline')
        env['CORE']=NS(BOOTFILENAME=Text('boot/boot.ksm'))
        env['SHIP']=NS(THRUST=.1 if failure=='thrust' else 0,
                       CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
        files['0:/boot/boot.ks']='new bootstrap'
        files['1:/boot/boot.ksm']=('ksm','old')
        if failure=='copy':env['COPYPATH']=lambda *_:None
        env['run_body'](body)
        assert env['CORE'].BOOTFILENAME=='boot/boot.ksm'
        assert files['1:/boot/boot.ksm']==('ksm','old')
    print('PASS: boot updater compiles on archive, preserves the selected previous boot, selects only a copied replacement, and leaves mission state untouched; offline/thrust/copy failures cannot select a missing file')

if __name__=='__main__':
    check_legacy_and_compiled_resolution()
    check_shared_install_and_offline_main()
    check_bootstrap_full_disk_fallback_and_missing_exports()
    check_full_hop_disk_and_reserved_cache()
    check_cache_is_not_executed()
    check_profile_listing_and_generation()
    check_boot_entry_and_missing_main()
    check_boot_update_install()
