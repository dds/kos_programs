"""Relay source with an independent two-body impulse adapter; not native KSP."""
import copy
import math
import re
from functools import lru_cache
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, closure, dependency_tables, function_body, command_entrypoint_errors
from check_espoir_fleet import Items, Map, Text, native, profile
from check_minmus_kolniya import executable
from check_surface_return import read_settings

HARDWARE=(ROOT/'lib/relay_hardware.ks').read_text()
CONTROL=(ROOT/'lib/relay_constellation.ks').read_text()
RELEASE=(ROOT/'lib/relay_release.ks').read_text()
SHARED=set(re.findall(r'GLOBAL (\w+) IS',HARDWARE+CONTROL)) | {
    'BURN_STAGE_MAX_EVENTS','BURN_STAGE_MANUAL_WAIT','BURN_TRIM_ABS_COMPLETE_DV',
    'BURN_TRIM_COMPLETE_MAX_DV','ABORT','WARP','SAS','HASNODE','NEXTNODE'}
MATH=dict(SQRT=math.sqrt,COS=lambda x:math.cos(math.radians(x)),CEILING=math.ceil,
          ROUND=round,CONSTANT=NS(PI=math.pi),VANG=lambda *_:0)


class Record(Map):
    def __init__(self,items=()):super().__init__((str(k),v) for k,v in items)
    def __setitem__(self,key,value):dict.__setitem__(self,str(key),value)


class Scope(dict):
    def __init__(self,root,values):self.root=root;super().__init__(values)
    def __getitem__(self,key):
        if key in SHARED and key in self.root:return self.root[key]
        return dict.__getitem__(self,key)
    def __setitem__(self,key,value):
        dict.__setitem__(self,key,value)
        if key in SHARED:self.root[key]=value


@lru_cache(None)
def prepared(source,name):
    code=function_body(source,name);names=[];defaults={}
    for group in re.findall(r'PARAMETER ([^.]+)\.',code):
        for raw in group.split(','):
            fields=raw.strip().split(' IS ');names.append(fields[0])
            if len(fields)>1:defaults[fields[0]]={'FALSE':False,'TRUE':True,'""':Text('')}[fields[1]]
    code=re.sub(r'PARAMETER [^.]+\.','',code)
    code=re.sub(r'WAIT UNTIL [^.]+\.','fixture_settle().',code)
    code=code.replace('REMOVE nd.','fixture_remove(nd).')
    code=code.replace('REBOOT.','fixture_reboot().')
    code=re.sub(r'\b(\w+)@',r'fixture_delegate(\1)',code)
    # Native strings coerce scalars during concatenation; Python strings do
    # not. Keep actual control/math source, adapt only literal string values.
    code=re.sub(r'"(?:\\.|[^"\\])*"',lambda m:'fixture_text('+m[0]+')',code)
    return names,defaults,ks.compile_nodes(ks.freeze(executable(code)))


def invoke(source,name,env,*args):
    names,defaults,compiled=prepared(source,name)
    local=Scope(env,{**env,**defaults,**dict(zip(names,args))}) if names else env
    try:ks.execute(compiled,local)
    except ks.Returned as result:return result.value


class Module:
    def __init__(self,events=()):self.events=set(events);self.calls=[]
    def HASEVENT(self,name):return str(name) in self.events
    def DOEVENT(self,name):
        name=str(name)
        assert name in self.events
        self.calls.append(name)
        if name=='Extend Antenna':self.events={'Retract Antenna'}


class Part:
    def __init__(self,uid,name='part',tag='',modules=None,resources=()):
        self.UID=Text(uid);self.NAME=Text(name);self.TAG=Text(tag)
        self.modules={} if modules is None else modules
        self.RESOURCES=Items(resources);self.CHILDREN=Items();self.ISDECOUPLED=False;self.STAGED=False;self.EJECTIONFORCE=0
    def HASMODULE(self,name):return str(name) in self.modules
    def GETMODULE(self,name):assert str(name) in self.modules,name;return self.modules[str(name)]
    def ISTYPE(self,name):return name=='Separator' and self.HASMODULE('ModuleAnchoredDecoupler')


class Orbit:
    def __init__(self,body,a,e=0,ap_ut=2000):
        self.BODY=body;self.a=a;self.e=e;self.ap_ut=ap_ut;self.HASNEXTPATCH=False
    PERIOD=property(lambda s:2*math.pi*math.sqrt(s.a**3/s.BODY.MU))
    SEMIMAJORAXIS=property(lambda s:s.a)
    ECCENTRICITY=property(lambda s:s.e)
    APOAPSIS=property(lambda s:s.a*(1+s.e)-s.BODY.RADIUS)
    PERIAPSIS=property(lambda s:s.a*(1-s.e)-s.BODY.RADIUS)


class Carrier:
    def __init__(self,bdy,altitude):
        self.BODY=bdy;self.ORBIT=Orbit(bdy,bdy.RADIUS+altitude)
        self.STATUS=Text('ORBITING');self.THRUST=0
        self.CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0)
        self.FACING=NS(FOREVECTOR=None);self.PROGRADE=NS(FOREVECTOR=None);self.ANGULARVEL=NS(MAG=0)
        self.PARTS=Items();self.NAME=Text('Espoir-Carrier');self.DELTAV=NS(VACUUM=1000)
    APOAPSIS=property(lambda s:s.ORBIT.APOAPSIS)
    PERIAPSIS=property(lambda s:s.ORBIT.PERIAPSIS)
    def PARTSTAGGED(self,tag):return Items(p for p in self.PARTS if p.TAG==tag)


class Eta:
    def __init__(self,ship,clock):self.ship=ship;self.clock=clock
    APOAPSIS=property(lambda s:(s.ship.ORBIT.ap_ut-s.clock.SECONDS)%s.ship.ORBIT.PERIOD)
    PERIAPSIS=property(lambda s:(s.ship.ORBIT.ap_ut+s.ship.ORBIT.PERIOD/2-s.clock.SECONDS)%s.ship.ORBIT.PERIOD)


def fixture(body='Mun'):
    cfg=read_settings(HARDWARE,{},'GLOBAL');cfg.update(profile(body.lower()+'_relay_tripack'));cfg=native(cfg)
    radius,mu,soi=(200000,6.5138398e10,2429559) if body=='Mun' else (60000,1.7658e9,2247428)
    bdy=NS(NAME=Text(body),RADIUS=radius,MU=mu,SOIRADIUS=soi,ATM=NS(EXISTS=False,HEIGHT=0))
    ship=Carrier(bdy,cfg['RELAY_ALT']);clock=NS(SECONDS=1000.);stage=NS(DELTAV=NS(VACUUM=1000))
    core=Part('carrier-core');ship.PARTS.append(core)
    saved={'mission_id':Text(cfg['MISSION_ID']),'launch_time':native(100),'phase':Text('RELAY_CONSTELLATION')}
    events=[];alarms={};released=[];nodes=[];steering=[False]
    def lex(*xs):return Record(zip(xs[::2],xs[1::2]))
    def put(key,value):
        # Model durable values; no native part/node/closure may enter JSON state.
        import json
        json.dumps(value)
        saved[key]=copy.deepcopy(value)
    def wait(dt):clock.SECONDS+=dt
    env=dict(cfg,**MATH,SHIP=ship,CORE=NS(PART=core),KUNIVERSE=NS(ACTIVEVESSEL=ship,TIMEWARP=NS(ISSETTLED=True)),
        TIME=clock,STAGE=stage,ETA=Eta(ship,clock),ABORT=False,WARP=0,HASNODE=False,
        CIRCULAR_ECC_LIMIT=.001,LIST=lambda *xs:Items(xs),LEXICON=lex,
        fixture_text=Text,fixture_delegate=lambda fn:NS(CALL=fn),
        stateGet=lambda k,d='':saved.get(k,d),stateGetNum=lambda k,d=0:saved.get(k,d),stateSet=put,
        maneuverBurnInterrupted=lambda:False,missionTargetBody=lambda:bdy,BODY=lambda _:bdy,
        fixture_wait=wait,fixture_settle=lambda:None,
        fixture_lock=lambda _:steering.__setitem__(0,True),fixture_unlock=lambda:steering.__setitem__(0,False),
        steering_lock=steering,
        yieldToPrompt=lambda:events.append('hold'),thrustCutoffOk=lambda:True,
        BURN_STAGE_MAX_EVENTS=4,BURN_STAGE_MANUAL_WAIT=120,BURN_TRIM_ABS_COMPLETE_DV=.05,
        BURN_TRIM_COMPLETE_MAX_DV=.05,nextPhase=lambda _:events.append('next'),xferSeq=cfg['SEQUENCE'])
    for idx in range(1,4):
        dec=Part('dc'+str(idx),tag='relay_'+str(idx),modules={'ModuleAnchoredDecoupler':Module(['Decouple'])})
        probe=Part('probe'+str(idx),modules={'ModuleCommand':Module()},
                   resources=[NS(NAME='ElectricCharge',AMOUNT=300,CAPACITY=300)])
        ant=Part('ant'+str(idx),name='restock-relay-radial-2_v2',
                 modules={'ModuleDataTransmitter':Module(),'ModuleDeployableAntenna':Module(['Extend Antenna'])})
        panels=[Part('sol'+str(idx)+'-'+str(j),modules={'ModuleDeployableSolarPanel':Module()}) for j in range(6)]
        parts=Items([probe,ant,*panels]);dec.CHILDREN=parts
        for part in [dec,*parts]:part.SHIP=ship;ship.PARTS.append(part)
        def release(event,dec=dec,parts=parts,idx=idx):
            assert event=='Decouple' and not dec.ISDECOUPLED
            dec.ISDECOUPLED=True
            child=NS(BODY=bdy,ORBIT=copy.copy(ship.ORBIT),NAME=Text('Relay'))
            for p in parts:ship.PARTS.remove(p);p.SHIP=child
            released.append((idx,clock.SECONDS,child));events.append(('release',idx))
        dec.modules['ModuleAnchoredDecoupler'].DOEVENT=release
    class Node:
        def __init__(self,ut,pro):self.TIME=ut;self.pro=pro;self.DELTAV=NS(MAG=abs(pro))
    def add(nd):
        assert not nodes
        nodes.append(nd);env.update(HASNODE=True,NEXTNODE=nd)
    def remove(nd):nodes.remove(nd);env['HASNODE']=bool(nodes)
    def circularize():
        orb=ship.ORBIT;rp=bdy.RADIUS+ship.APOAPSIS
        dv=math.sqrt(mu/rp)-math.sqrt(mu*(2/rp-1/orb.a))
        nd=Node(clock.SECONDS+env['ETA'].APOAPSIS,dv);add(nd);return nd
    def burn():
        assert env['BURN_STAGE_MAX_EVENTS']==env['BURN_STAGE_MANUAL_WAIT']==0
        assert env['BURN_TRIM_ABS_COMPLETE_DV']==env['BURN_TRIM_COMPLETE_MAX_DV']==.001
        nd=nodes[0];old=ship.ORBIT;phase=(nd.TIME-old.ap_ut)%old.PERIOD
        at_ap=min(phase,old.PERIOD-phase)<old.PERIOD/4
        r=bdy.RADIUS+(old.APOAPSIS if at_ap else old.PERIAPSIS)
        v=math.sqrt(mu*(2/r-1/old.a))+nd.pro
        a=1/(2/r-v*v/mu);e=abs(1-r/a)
        new=Orbit(bdy,a,e,nd.TIME)
        if r<a:new.ap_ut=nd.TIME+new.PERIOD/2
        ship.ORBIT=new;clock.SECONDS=nd.TIME+3;stage.DELTAV.VACUUM-=abs(nd.pro)
        events.append(('burn',nd.pro,nd.TIME));remove(nd);return True
    def alarm(name,ut,*_):alarms[name]=ut;events.append(('alarm',name,ut));return name
    def solar(label,orient,health,deadline):
        assert alarms or env.get('no_kac')
        events.append(('solar',deadline));return .8
    def coast(b,wake,poll,alarm_id,solar_ref,health,stay):
        assert b is bdy and poll==5 and stay and (alarm_id in alarms or env.get('no_kac'))
        assert wake==events[-1][1] and not nodes
        clock.SECONDS=max(clock.SECONDS,wake)
    env.update(NODE=lambda ut,rad,nor,pro:Node(ut,pro),fixture_add=add,fixture_remove=remove,
        planCircularize=circularize,executeManeuver=burn,kacEnsureAlarm=alarm,
        DELETEALARM=lambda key:alarms.pop(key),enterSolarCoast=solar,waitUntilOrSOI=coast)
    for source in (HARDWARE,RELEASE,CONTROL):
        for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',source):
            env[name]=lambda *args,source=source,name=name:invoke(source,name,env,*args)
    return env,ship,saved,events,alarms,released,nodes


def check_profiles_geometry_and_coverage():
    deps,phases,bands=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for body in ('Mun','Minmus'):
        env,ship,*_=fixture(body)
        geom=env['relayGeometry'](3,env['RELAY_ALT'],ship.BODY)
        assert geom['OK'] and geom['PHASE_PE']>5000
        assert abs(geom['PHASE_PERIOD']/geom['PERIOD']-2/3)<1e-12
        # Independent Kepler period of the derived phasing apses.
        r=ship.BODY.RADIUS+env['RELAY_ALT'];pe=ship.BODY.RADIUS+geom['PHASE_PE']
        assert abs(2*math.pi*math.sqrt(((r+pe)/2)**3/ship.BODY.MU)-geom['PHASE_PERIOD'])<1e-8
        limit=math.degrees(math.acos(2*ship.BODY.RADIUS/r))
        for lat,always in ((0,True),(limit-.01,True),(89,False)):
            visible=[]
            for angle in range(360):
                best=max(r*math.cos(math.radians(lat))*math.cos(math.radians(angle-120*i))-ship.BODY.RADIUS for i in range(3))
                visible.append(best>=0)
            assert all(visible)==always
        assert math.sqrt(3)*r<20e6 # HG-20 relay-to-relay distance.
        assert r<math.sqrt(20e6*500000) # Communotron16 client; core-only5000 is insufficient.
        cfg=profile(body.lower()+'_relay_tripack')
        assert cfg['CAPTURE_INC']==cfg['SHAPE_INC']==0 and cfg['CAPTURE_PE']==cfg['TARGET_AP']==cfg['RELAY_ALT']
        assert cfg['COAST_AUTO_WARP']==0 and cfg['RELAY_COUNT']==3 and cfg['RELAY_VERIFY_HARDWARE']==1
        for phase in cfg['SEQUENCE']:assert phase.lower() in phases
    assert {'relay_hardware','coast_wait','maneuver'} <= closure(phases['relay_constellation'],deps)
    assert 'relay_hardware' not in closure(phases['capture'],deps)
    assert bands['relay_constellation']==['relay_constellation']
    print('PASS: two Espoir tripacks, safe2:3 phasing, independent period/LOS/range calculations; equatorial starter rings cover their latitude bands and explicitly fail polar coverage')


def check_inventory_and_release_guards():
    for fault in ('ok','tag','duplicate','staged','core','nested','command','antenna','panels','battery','charge','nan-charge','engine'):
        env,ship,saved,events,*_=fixture()
        dc=ship.PARTSTAGGED('relay_1')[0];parts=dc.CHILDREN
        if fault=='tag':dc.TAG=Text('wrong')
        if fault=='duplicate':ship.PARTS.append(dc)
        if fault=='staged':dc.STAGED=True
        if fault=='core':parts.append(env['CORE'].PART)
        if fault=='nested':parts.append(ship.PARTSTAGGED('relay_2')[0])
        if fault=='command':parts[0].modules.clear()
        if fault=='antenna':parts[1].NAME=Text('restock-antenna-stack-2') # DIRECT DTS-J1 is not a relay.
        if fault=='panels':parts[-1].modules.clear()
        if fault=='battery':parts[0].RESOURCES[0].CAPACITY=100
        if fault=='charge':parts[0].RESOURCES[0].AMOUNT=10
        if fault=='nan-charge':parts[0].RESOURCES[0].AMOUNT=math.nan
        if fault=='engine':parts[0].modules['ModuleEnginesFX']=Module()
        before=copy.deepcopy(saved)
        info=env['relayPayloadInfo'](1)
        assert info['OK']==(fault=='ok'),(fault,info['REASON'])
        assert saved==before and not events
    for fault in ('abort','node','interrupted','pilot','active','body','budget','antenna-jam','ledger'):
        env,ship,saved,events,alarms,released,nodes=fixture()
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True;nodes.append(object())
        if fault=='interrupted':env['maneuverBurnInterrupted']=lambda:True
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='active':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        if fault=='body':ship.BODY=NS(NAME='Kerbin',MU=3.5316e12,RADIUS=600000,SOIRADIUS=84159286,ATM=NS(EXISTS=True,HEIGHT=70000))
        if fault=='budget':env['STAGE'].DELTAV.VACUUM=100
        if fault=='ledger':saved['relay_campaign_id']=Text('another-flight')
        if fault=='antenna-jam':
            ant=ship.PARTSTAGGED('relay_1')[0].CHILDREN[1].GETMODULE('ModuleDeployableAntenna')
            ant.DOEVENT=lambda _:None
        assert not env['constellationDeploy'](3,env['RELAY_ALT'])
        assert not released and not alarms and not any(isinstance(e,tuple) and e[0]=='burn' for e in events)
        assert not env['steering_lock'][0]
        if fault=='node':assert nodes and env['HASNODE']
    print('PASS: real inventory refuses missing/duplicate/overlapping/staged/dead/direct-only payloads; Abort, foreign/interrupted nodes, pilot input, wrong craft/body, fuel and jammed antennas prevent release without clearing maneuvers')


def check_three_satellite_deployment_and_reboots():
    class Reboot(Exception):pass
    for body,cut in (('Mun','none'),('Minmus','none'),('Mun','inserted'),('Mun','circularized'),('Mun','missed-return'),('Minmus','no-kac')):
        env,ship,saved,events,alarms,released,nodes=fixture(body)
        original_put=env['stateSet'];fired=[False]
        def checkpoint(key,value):
            original_put(key,value)
            if not fired[0] and ((cut in ('inserted','missed-return') and key=='relay_1_phase_inserted')
                    or (cut=='circularized' and key=='relay_1_phase_complete')):
                fired[0]=True;raise Reboot()
        env['stateSet']=checkpoint
        if cut=='no-kac':env.update(no_kac=True,kacEnsureAlarm=lambda *_:'')
        try:result=env['constellationDeploy'](3,env['RELAY_ALT'])
        except Reboot:
            if cut=='missed-return':
                # Persist an already missed first return, then resume well
                # after it: the compatible next wake skips3, not1, orbits.
                saved['relay_1_return_ut']=env['TIME'].SECONDS+env['ETA'].APOAPSIS
                old=saved['relay_1_return_ut'];env['TIME'].SECONDS=old+10
            result=env['constellationDeploy'](3,env['RELAY_ALT'])
        assert result and not nodes and not alarms,(body,cut,events)
        assert [x[0] for x in released]==[1,2,3] and saved['relay_deployed_count']==3
        assert len([e for e in events if isinstance(e,tuple) and e[0]=='burn'])==4
        assert all(abs(x[2].ORBIT.PERIOD-released[0][2].ORBIT.PERIOD)<=env['RELAY_PERIOD_TOLERANCE'] for x in released)
        assert env['BURN_STAGE_MAX_EVENTS']==4 and env['BURN_TRIM_ABS_COMPLETE_DV']==.05
        assert env['constellationDeploy'](3,env['RELAY_ALT']) and len(released)==3 # idempotent completed reboot
        if cut=='missed-return':
            assert abs((saved['relay_1_return_ut']-old)/released[0][2].ORBIT.PERIOD-2)<1e-8
    # Explicit period mismatch gets corrected by the actual bounded planner.
    env,ship,saved,events,_,_,_=fixture()
    saved['relay_1_record']=Map(PERIOD=ship.ORBIT.PERIOD-20,VALID=True)
    assert env['_relayMatchPeriod']()
    assert abs(ship.ORBIT.PERIOD-saved['relay_1_record']['PERIOD'])<=env['RELAY_PERIOD_TOLERANCE']
    print('PASS: real controller releases three passive payloads with4 conic-checked burns, matching periods, KAC-before-solar waits, no-KAC polling and no auto-staging; rebooted insertion/circularization/missed apsis/completed campaigns never release twice or add a wrong phasing lap')


def check_ambiguous_release_and_wait_abort():
    env,ship,saved,events,alarms,released,nodes=fixture()
    dc=ship.PARTSTAGGED('relay_1')[0]
    saved['relay_1_intent']=Map(UIDS=Items(p.UID for p in dc.CHILDREN),DC=dc.UID,TIME=1000)
    dc.GETMODULE('ModuleAnchoredDecoupler').DOEVENT('Decouple')
    assert not env['constellationDeploy'](3,env['RELAY_ALT'])
    assert len(released)==1 and 'relay_1_record' not in saved
    env,ship,saved,events,alarms,released,nodes=fixture()
    def abort_wait(*_):env['ABORT']=True
    env['waitUntilOrSOI']=abort_wait
    assert not env['constellationDeploy'](3,env['RELAY_ALT'])
    assert len(released)==1 and not alarms and not nodes
    assert len([e for e in events if isinstance(e,tuple) and e[0]=='burn'])==1
    # A release kick that changes the native period is a real release, but
    # not a successful constellation. Preserve evidence and stop before#3.
    env,ship,saved,events,alarms,released,nodes=fixture()
    dc=ship.PARTSTAGGED('relay_2')[0];root=dc.CHILDREN[0]
    original=dc.GETMODULE('ModuleAnchoredDecoupler').DOEVENT
    def kick(event):
        original(event)
        orb=root.SHIP.ORBIT
        orb.a*=((orb.PERIOD+30)/orb.PERIOD)**(2/3)
    dc.GETMODULE('ModuleAnchoredDecoupler').DOEVENT=kick
    assert not env['constellationDeploy'](3,env['RELAY_ALT'])
    assert len(released)==2 and not saved['relay_2_record']['VALID']
    assert not env['constellationDeploy'](3,env['RELAY_ALT']) and len(released)==2
    print('PASS: crash between physical separation and period proof holds instead of guessing; Abort during the resident phasing wait cleans its alarm and never circularizes or releases the next payload')


def check_live_atmospheric_phasing_floor():
    env,ship,saved,events,alarms,released,nodes=fixture()
    ship.BODY.ATM.EXISTS=True;ship.BODY.ATM.HEIGHT=70000
    # The nominal geometry clears the existing atmosphere+5km floor by5cm.
    # A half-second period difference, already inside the relay tolerance,
    # moves the live phasing Pe below that floor. Re-prove it before burning.
    radius=(ship.BODY.RADIUS+75000.05)/(2*(2/3)**(2/3)-1)
    ship.ORBIT.a=radius;altitude=radius-ship.BODY.RADIUS
    assert env['relayGeometry'](3,altitude,ship.BODY)['OK']
    saved['relay_1_record']=Map(PERIOD=ship.ORBIT.PERIOD-.5,VALID=True)
    assert not env['_phaseCarrierOneSlot'](3,altitude,ship.BODY,1)
    assert not nodes and not released and not alarms and not events
    print('PASS: live reference-period phasing retains the original atmosphere+5km floor even when nominal geometry passed; near-boundary drift cannot authorize a lower unsafe burn')


def check_read_only_diagnostic():
    source=(ROOT/'cmd/relaycheck.ks').read_text()
    assert not command_entrypoint_errors(source)
    for fault in ('ok','no-link','pilot','warp','inactive'):
        env,ship,saved,events,_,released,nodes=fixture()
        saved.update(vehicle=Text('Espoir'));env['HASNODE']=True;nodes.append(object())
        rows=[];loads=[];before=copy.deepcopy(saved)
        env.update(RUNPATH=lambda _:None,bootPreamble=lambda:None,bootLibLoad=loads.append,
            bootApplyMissionConfig=lambda *_:True,BODYEXISTS=lambda _:True,getTarget=lambda:ship.BODY.NAME,
            HOMECONNECTION=NS(ISCONNECTED=fault!='no-link'),
            diagnosticArchiveOpen=lambda _:Map(READY=fault!='no-link'),
            diagnosticArchiveLine=lambda report,row:rows.append(str(row)),diagnosticArchiveClose=lambda *_:True)
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='warp':env['WARP']=1
        if fault=='inactive':env['KUNIVERSE'].ACTIVEVESSEL=NS()
        invoke(source,'_cmdRelaycheck',env)
        assert saved==before and not events and not released and nodes and env['HASNODE']
        if fault=='ok':assert len(rows)==5 and loads==['relay_hardware','diagnostic_log']
        else:assert not rows
    print('PASS: wrapped relaycheck records actual geometry/inventory directly through the archive provider, loads no maneuver engine, and preserves nodes, mission state and hardware; missing link or live controls cannot act')


if __name__=='__main__':
    check_profiles_geometry_and_coverage()
    check_inventory_and_release_guards()
    check_three_satellite_deployment_and_reboots()
    check_ambiguous_release_and_wait_abort()
    check_read_only_diagnostic()
    check_live_atmospheric_phasing_floor()
