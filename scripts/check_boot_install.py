"""Exercise boot file contracts with an exact-name fake disk, not a kOS compiler."""
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, function_body
from check_runtime_contracts import KString, KList, run

BOOT=(ROOT/'lib/boot_lib.ks').read_text()
CONFIG=(ROOT/'lib/config.ks').read_text()

class Text(KString):
    TRIM=property(lambda self:Text(self.strip()))
    def __add__(self,other):return Text(str(self)+str(other))
    def __radd__(self,other):return Text(str(other)+str(self))
    def SUBSTRING(self,start,count=None):return Text(super().SUBSTRING(start,count))
    def SPLIT(self,sep):return Items(map(Text,self.split(sep)))

class Items(KList):
    def CONTAINS(self,value):return value in self

def fixture(linked=True,extra_source=''):
    fixture_source=BOOT+'\n'+CONFIG+'\n'+extra_source
    files,events,state={},[],{}
    cwd=[Text('1:/')]
    env=dict(HOMECONNECTION=NS(ISCONNECTED=linked),HAS_LINK=linked,
        EXISTS=lambda path:exists(path),CREATEDIR=lambda path:files.update({str(path):None}),
        COPYPATH=lambda src,dest:copy(src,dest),DELETEPATH=lambda path:files.pop(str(path)),
        PATH=lambda:cwd[0],CD=lambda path:cwd.__setitem__(0,Text(path)),
        LIST=lambda *xs:Items(xs),text=Text,BOOT_LIB_RAN=Items(),
        stateGet=state.get,stateGetNum=state.get,
        stateSet=lambda key,value:state.update({key:value}),stateRemove=lambda key:state.pop(key,None),
        SHIP=NS(STATUS='ORBITING'),BOOT_MANUAL_REQUESTED=False,phaseShouldYield=False,
        MISSION_ID='',MISSION_NAME='',TARGET_='',MISSION_TYPE='',PAYLOADS=Items(),
        applyKnownMissionState=lambda:None,getTarget=lambda *_:env['TARGET_'],
        bootLibResolve=lambda roots:roots,bootLibArchiveOnly=lambda _:False,
        bootLibAddUnique=lambda dest,key:dest.ADD(key) if key not in dest else None,
        yieldToPrompt=lambda:env.update(phaseShouldYield=True))
    def exists(path):
        if str(path).startswith('0:/'):assert env['HOMECONNECTION'].ISCONNECTED
        return str(path).replace('/./','/') in files
    def copy(src,dest):
        assert exists(src)
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
        return re.sub(r'"[^"\n]*"',lambda match:'text('+match[0]+')',source)
    env.update(compile_file=compile_file,listing=listing,RUNPATH=running,RUNONCEPATH=running)
    prepared={}
    def invoke(name,*args):
        if name not in prepared:
            body=function_body(fixture_source,name)
            prepared[name]=(re.findall(r'PARAMETER (\w+)',body),ks.compile_nodes(ks.freeze(ks.parse(adapt(body)))))
        params,compiled=prepared[name]
        local=env if name in ('bootApplyMissionConfig','main') else dict(env)
        local.update(zip(params,args))
        try:ks.execute(compiled,local)
        except ks.Returned as result:return result.value
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',fixture_source):
        env[name]=lambda *args,name=name:invoke(name,*args)
    env['bootLibResolve']=lambda roots:roots
    env['bootLibArchiveOnly']=lambda _:False
    env['run_body']=lambda source:run(adapt(source),env)
    return env,files,events,state

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
    check_profile_listing_and_generation()
    check_boot_entry_and_missing_main()
    check_boot_update_install()
