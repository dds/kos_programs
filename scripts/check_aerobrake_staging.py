"""Serial-stage handoffs and interruption fixtures; no native KSP staging."""
import math
import re
from types import SimpleNamespace as NS

import check_landing_guidance as ks
from check_codebase import ROOT, closure, dependency_tables, function_body, mask
from check_runtime_contracts import KList
from check_aerobrake_assist import SOURCE as ASSIST, AERO, fixture as flight_fixture

SOURCE=(ROOT/'lib/aerobrake_staging.ks').read_text()
ks.SOURCES+='\n'+SOURCE


class Map(dict):
    LENGTH=property(len)
    VALUES=property(lambda self:KList(self.values()))


class Seq(KList):
    CONTAINS=list.__contains__


class Part(NS):
    # Native equality is physical part identity, not structural equality.
    def __eq__(self,other):return self is other
    def __ne__(self,other):return self is not other


def fixture():
    events=[];saved={}
    def part(uid,stage,group,mass,modules=()):
        return Part(UID=uid,NAME=uid,TAG='',STAGE=stage,DECOUPLEDIN=group,MASS=mass,
                    MODULES=Seq(modules),RESOURCES=KList(),HASMODULE=lambda name:name in modules)
    core=part('core',-1,-1,.1)
    chute=part('chute',0,-1,.1,('ModuleParachute',))
    release=part('release',2,2,.025,('ModuleDecouple',))
    returning=part('return',1,1,.025,('ModuleDecouple',))
    for separator in (release,returning):separator.STAGED=True;separator.ISDECOUPLED=False
    engines=[];tanks=[]
    for index,(mass,thrust,isp) in enumerate(((.1,55,355),(.1,20,315),(.1,2,315))):
        stage=3-index;group=stage-1 if stage>1 else -1
        eng=part('engine'+str(stage),stage,group,mass)
        eng.__dict__.update(IGNITION=stage==3,THROTTLELOCK=False,MULTIMODE=False,
                            FLAMEOUT=False,ALLOWRESTART=True,AVAILABLETHRUST=thrust if stage==3 else 0,
                            POSSIBLETHRUST=thrust,VISP=isp,
                            CONSUMEDRESOURCES=Map(fuel=NS(NAME='LiquidFuel',RATIO=.9,DENSITY=.005),
                                                  oxidizer=NS(NAME='Oxidizer',RATIO=1.1,DENSITY=.005)))
        engines.append(eng)
        tank=part('tank'+str(stage),-1,group,.2)
        tank.RESOURCES=KList([NS(NAME='LiquidFuel',AMOUNT=9.,ENABLED=True),
                              NS(NAME='Oxidizer',AMOUNT=11.,ENABLED=True)])
        tanks.append(tank)
    tags={'lander_decoupler':KList([release]),'return_decoupler':KList([returning]),'descent_chutes':KList([chute])}
    ship=NS(PARTS=KList([core,chute,release,returning,*engines,*tanks]),ENGINES=KList(engines),
            PARTSTAGGED=lambda tag:tags.get(tag,KList()),MASS=1.25,
            BODY=NS(NAME='Kerbin'),ORBIT=NS(ECCENTRICITY=.8),STATUS='ORBITING',
            THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),
            ALTITUDE=100000,PERIAPSIS=53000,APOAPSIS=211500,Q=0)
    env=ks.environment()
    env.update(SHIP=ship,CORE=NS(PART=core),STAGE=NS(NUMBER=3,READY=True,DELTAV=NS(VACUUM=10)),
               AEROBRAKE_AP_STAGE_TAGS=KList(['lander_decoupler','return_decoupler']),
               AEROBRAKE_AP_BURN=1,AEROBRAKE_AP_MAX_Q=.1,AEROBRAKE_REENTRY_DIR='RETROGRADE',
               LOG_ARCHIVE_DEFERRED=0,WARP=0,KUNIVERSE=NS(TIMEWARP=NS(ISSETTLED=True)),
               HASNODE=False,phaseShouldYield=False,LIST=lambda *args:Seq(args),LEXICON=lambda *args:Map(zip(args[::2],args[1::2])),
               LN=math.log,CONSTANT=NS(G0=9.80665),stateGet=saved.get,
               aerobrakeApReserveDv=lambda:10,aerobrakeApEntryEta=lambda _:180,
               fixture_lock=lambda statement:events.append(('lock',statement)),
               fixture_wait=lambda dt:events.append(('wait',dt)))
    def persist(key,value):
        assert ship.THRUST<=.001
        events.append(('state',key,value));saved[key]=value
    def cutoff(*args):
        events.append(('cutoff',));assert ship.THRUST<=.001
        return True
    def stage():
        assert ship.THRUST==ship.CONTROL.MAINTHROTTLE==ship.CONTROL.PILOTMAINTHROTTLE==0
        assert saved['aerobrake_ap_stage_attempt'] in ('release','return')
        assert not saved.get('aerobrake_ap_active',False)
        boundary=env['STAGE'].NUMBER-1
        events.append(('stage',boundary))
        separator=release if boundary==2 else returning
        separator.ISDECOUPLED=True
        ship.PARTS[:]=[p for p in ship.PARTS if p.DECOUPLEDIN<boundary]
        ship.ENGINES[:]=[e for e in ship.ENGINES if e.DECOUPLEDIN<boundary]
        env['STAGE'].NUMBER=boundary
        for eng in ship.ENGINES:
            if eng.STAGE==boundary:eng.IGNITION=True;eng.AVAILABLETHRUST=eng.POSSIBLETHRUST
        ship.MASS=sum(p.MASS for p in ship.PARTS)
        env['STAGE'].DELTAV.VACUUM=400
    def hold():env['phaseShouldYield']=True;events.append(('hold',))
    env.update(stateSet=persist,thrustCutoffOk=cutoff,stage_event=stage,yieldToPrompt=hold)
    for name in re.findall(r'(?:GLOBAL|LOCAL) FUNCTION (\w+)',SOURCE):
        env[name]=lambda *args,name=name:ks.call(name,env,*args)
    def set_fuel(index,dv):
        # Independent inverse rocket equation creates the requested budget
        # in just this stage's 0.9:1.1 mixture. Keep vessel wet mass fixed.
        fuel_mass=ship.MASS*(1-math.exp(-dv/(engines[index].VISP*9.80665)))
        tanks[index].RESOURCES[0].AMOUNT=fuel_mass/.005*.45
        tanks[index].RESOURCES[1].AMOUNT=fuel_mass/.005*.55
    set_fuel(0,10)
    return env,events,saved,tags,engines,tanks,set_fuel


def run(env):return env['aerobrakeApStageCoast'](70000,52000,54000)


def check_two_handoffs():
    env,events,saved,tags,engines,tanks,set_fuel=fixture()
    assert run(env)
    assert env['STAGE'].NUMBER==2 and engines[1].IGNITION and not engines[2].IGNITION
    assert saved['aerobrake_ap_stage_attempt']=='release'
    assert [e for e in events if e[0]=='stage']==[('stage',2)]
    assert events.index(('cutoff',))<next(i for i,e in enumerate(events) if e[0]=='state')<events.index(('stage',2))
    assert events[-1]==('cutoff',) and env['LOG_ARCHIVE_DEFERRED']==0
    assert not run(env) # Fresh lander fuel cannot be thrown away.
    env['STAGE'].DELTAV.VACUUM=10;set_fuel(1,10)
    assert run(env) and env['STAGE'].NUMBER==1 and engines[2].IGNITION
    assert not run(env) # Never stage into the parachute slot.
    assert env['CORE'].PART in env['SHIP'].PARTS
    assert tags['descent_chutes'][0] in env['SHIP'].PARTS
    assert [e for e in events if e[0]=='stage']==[('stage',2),('stage',1)]
    print('PASS: two separate reserve-limited 3→2→1 coast handoffs verify cutoff before each event, preserve CPU/chutes, wait for fuel use and never advance into stage0')


def check_rejections():
    cases=('off','no-tags','abort','node','hold','active-burn','thrust','raw','pilot','atmo',
           'margin','unbound','pe-low','pe-high','q','warp','unsettled','not-ready','late',
           'prograde','landed','missing-tag','duplicate-tag','wrong-part','spent','unstaged','cpu',
           'no-chutes','discarded-chute','wrong-chute','prior-attempt','two-current','no-current',
           'wrong-group','wrong-current-stage','next-active','next-flameout','next-solid','next-multimode',
           'no-restart','next-no-thrust','unknown-slot','extra-separator','stock-has-fuel',
           'physical-has-fuel','stock-nan','physical-nan','no-mixture','massless-mixture','disabled-next-fuel')
    for case in cases:
        env,events,saved,tags,engines,tanks,set_fuel=fixture();ship=env['SHIP']
        if case=='off':env['AEROBRAKE_AP_BURN']=0
        if case=='no-tags':env['AEROBRAKE_AP_STAGE_TAGS']=KList()
        if case=='abort':env['ABORT']=True
        if case=='node':env['HASNODE']=True
        if case=='hold':env['phaseShouldYield']=True
        if case=='active-burn':saved['aerobrake_ap_active']=True
        if case=='thrust':ship.THRUST=.01
        if case=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if case=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if case=='atmo':ship.ALTITUDE=69000
        if case=='margin':ship.ALTITUDE=71000
        if case=='unbound':ship.ORBIT.ECCENTRICITY=1.1
        if case=='pe-low':ship.PERIAPSIS=52099
        if case=='pe-high':ship.PERIAPSIS=53901
        if case=='q':ship.Q=.11
        if case=='warp':env['WARP']=1
        if case=='unsettled':env['KUNIVERSE'].TIMEWARP.ISSETTLED=False
        if case=='not-ready':env['STAGE'].READY=False
        if case=='late':env['aerobrakeApEntryEta']=lambda _:60
        if case=='prograde':env['AEROBRAKE_REENTRY_DIR']='PROGRADE'
        if case=='landed':ship.STATUS='LANDED'
        if case=='missing-tag':tags.pop('lander_decoupler')
        if case=='duplicate-tag':tags['lander_decoupler'].append(tags['lander_decoupler'][0])
        if case=='wrong-part':tags['lander_decoupler'][0].HASMODULE=lambda _:False
        if case=='spent':tags['lander_decoupler'][0].ISDECOUPLED=True
        if case=='unstaged':tags['lander_decoupler'][0].STAGED=False
        if case=='cpu':env['CORE'].PART.DECOUPLEDIN=2
        if case=='no-chutes':tags.pop('descent_chutes')
        if case=='discarded-chute':tags['descent_chutes'][0].DECOUPLEDIN=2
        if case=='wrong-chute':tags['descent_chutes'][0].HASMODULE=lambda _:False
        if case=='prior-attempt':saved['aerobrake_ap_stage_attempt']='release'
        if case=='two-current':engines[2].IGNITION=True
        if case=='no-current':engines[0].IGNITION=False
        if case=='wrong-group':engines[0].DECOUPLEDIN=1
        if case=='wrong-current-stage':engines[0].STAGE=4
        if case=='next-active':engines[1].IGNITION=True
        if case=='next-flameout':engines[1].FLAMEOUT=True
        if case=='next-solid':engines[1].THROTTLELOCK=True
        if case=='next-multimode':engines[1].MULTIMODE=True
        if case=='no-restart':engines[1].ALLOWRESTART=False
        if case=='next-no-thrust':engines[1].POSSIBLETHRUST=0
        if case=='unknown-slot':ship.PARTS.append(Part(NAME='unknown',TAG='',STAGE=2,DECOUPLEDIN=1,MODULES=Seq(['UnknownStagingModule'])))
        if case=='extra-separator':tags['return_decoupler'][0].STAGE=2
        if case=='stock-has-fuel':env['STAGE'].DELTAV.VACUUM=380
        if case=='physical-has-fuel':set_fuel(0,380);env['STAGE'].DELTAV.VACUUM=0
        if case=='stock-nan':env['STAGE'].DELTAV.VACUUM=float('nan')
        if case=='physical-nan':tanks[0].RESOURCES[0].AMOUNT=float('nan')
        if case=='no-mixture':engines[0].CONSUMEDRESOURCES=Map()
        if case=='massless-mixture':engines[0].CONSUMEDRESOURCES['fuel'].DENSITY=0
        if case=='disabled-next-fuel':tanks[1].RESOURCES[1].ENABLED=False
        assert not run(env),case
        assert not any(e[0] in ('stage','state','cutoff') for e in events),(case,events)
    print(f'PASS: {len(cases)} policy/context/hardware/fuel hazards refuse staging, including stale stock-zero with 380m/s physically left')


def check_native_slot_modules():
    env,events,saved,tags,engines,tanks,set_fuel=fixture()
    passive=['ModulePartVariants','ModuleCargoPart','KRnDModule','AYPart','KOSNameTag']
    # Native RO9 save: inert tanks/legs inherit stage1/2 indices. The
    # fairing-base stage2 can be spent/disabled already; it is disposable
    # with the transfer stage even if it still has a staging action.
    for tank in tanks:
        tank.STAGE=tank.DECOUPLEDIN;tank.MODULES=Seq(passive)
    leg=Part(UID='leg',NAME='leg',TAG='',STAGE=1,DECOUPLEDIN=1,MASS=.01,
             RESOURCES=KList(),MODULES=Seq(passive+['ModuleWheelBase','ModuleWheelSuspension',
                'ModuleWheelDeployment','ModuleWheelLock','ModuleWheelDamage','GPWSGear']))
    fairing=Part(UID='fairing',NAME='fairing',TAG='main_fairing',STAGE=2,DECOUPLEDIN=2,MASS=.01,
                RESOURCES=KList(),MODULES=Seq(passive+['ModuleProceduralFairing','ModuleCargoBay',
                    'ModuleTestSubject','ModuleStructuralNode','ModuleStructuralNodeToggle',
                    'ModuleRestockModifyFairingMaterials']))
    env['SHIP'].PARTS.extend((leg,fairing))
    env['SHIP'].MASS+=.02;set_fuel(0,10)
    for eng in engines:
        eng.MODULES=Seq(passive+['ModuleEnginesFX','ModuleTestSubject','ModuleJettison',
                               'FXModuleThrottleEffects','ModuleColorChanger'])
    for tag in ('lander_decoupler','return_decoupler'):
        tags[tag][0].MODULES=Seq(passive+['ModuleDecouple','ModuleToggleCrossfeed','ModuleTestSubject'])
    assert run(env) and env['STAGE'].NUMBER==2
    set_fuel(1,10);env['STAGE'].DELTAV.VACUUM=10
    assert run(env) and env['STAGE'].NUMBER==1
    for mutation in ('retained-fairing','unknown-on-engine','unknown-on-separator','extra-chute','extra-engine','extra-decoupler'):
        env,events,_,tags,engines,tanks,set_fuel=fixture()
        if mutation=='retained-fairing':
            env['SHIP'].PARTS.append(Part(NAME='fairing',TAG='main_fairing',STAGE=2,DECOUPLEDIN=1,
                                         MODULES=Seq(['ModuleProceduralFairing'])))
        if mutation=='unknown-on-engine':engines[1].MODULES.ADD('UnknownStagingModule')
        if mutation=='unknown-on-separator':tags['lander_decoupler'][0].MODULES.ADD('UnknownStagingModule')
        if mutation.startswith('extra-'):
            module={'extra-chute':'ModuleParachute','extra-engine':'ModuleEnginesFX',
                    'extra-decoupler':'ModuleDecouple'}[mutation]
            env['SHIP'].PARTS.append(Part(NAME='extra',TAG='',STAGE=2,DECOUPLEDIN=1,MODULES=Seq([module])))
        assert not run(env) and not any(e[0]=='stage' for e in events),mutation
    print('PASS: saved RO9 tank/leg/engine/separator/fairing module layout admits both slots; retained fairings, extra staging actuators and unknown modules on any part still block automation')


def check_interruption_and_revalidation():
    for point in ('first-cutoff','persist','after-event','verify','failed-separation','failed-ignition','unexpected-engine'):
        env,events,saved,tags,engines,tanks,set_fuel=fixture()
        cutoff=env['thrustCutoffOk'];persist=env['stateSet'];stage=env['stage_event'];calls=[0]
        def stop(*args):
            calls[0]+=1
            if point=='first-cutoff':env['phaseShouldYield']=True;return False
            if point=='verify' and calls[0]==2:env['phaseShouldYield']=True;return False
            return cutoff(*args)
        def save(key,value):
            persist(key,value)
            if point=='persist':raise RuntimeError('reboot')
        def action():
            stage()
            if point=='after-event':raise RuntimeError('reboot')
            if point=='failed-separation':env['SHIP'].ENGINES.append(engines[0])
            if point=='failed-ignition':engines[1].IGNITION=False
            if point=='unexpected-engine':engines[2].IGNITION=True
        env.update(thrustCutoffOk=stop,stateSet=save,stage_event=action)
        try:assert not run(env),point
        except RuntimeError as error:assert str(error)=='reboot'
        before=sum(e[0]=='stage' for e in events)
        env.update(thrustCutoffOk=cutoff,stateSet=persist,stage_event=stage,phaseShouldYield=False,LOG_ARCHIVE_DEFERRED=0)
        assert not run(env) or point=='first-cutoff' # Unattempted cutoff failure can be retried after manual release.
        assert sum(e[0]=='stage' for e in events)==before+(point=='first-cutoff'),point
    for mutation in ('node','abort','body','stage','fuel','engine','separator'):
        env,events,saved,tags,engines,tanks,set_fuel=fixture();persist=env['stateSet']
        def save(key,value):
            persist(key,value)
            if mutation=='node':env['HASNODE']=True
            if mutation=='abort':env['ABORT']=True
            if mutation=='body':env['SHIP'].BODY.NAME='Mun'
            if mutation=='stage':env['STAGE'].NUMBER=2
            if mutation=='fuel':set_fuel(0,380)
            if mutation=='engine':engines[1].THROTTLELOCK=True
            if mutation=='separator':tags['lander_decoupler'][0].STAGED=False
        env['stateSet']=save
        assert not run(env) and not any(e[0]=='stage' for e in events),mutation
    print('PASS: cutoff faults and interrupted/failed handoffs cannot repeat a recorded separator; context, engine, fuel and separator changes during persistence are rechecked before firing')


def check_fresh_forecast():
    env,events,saved,tags,engines,tanks,set_fuel=fixture()
    assert run(env)
    flight,sim,data,refresh=flight_fixture(before_entry=180)
    # Actual source forecast sees the post-separation wet mass and Spark,
    # not the discarded Torch or its earlier ignition/time/dV solution.
    hardware_ship=env['SHIP']
    for attr in ('MASS','ENGINES','PARTS'):setattr(flight['SHIP'],attr,getattr(hardware_ship,attr))
    flight['STAGE'].NUMBER=2;flight['STAGE'].DELTAV.VACUUM=400
    plan=flight['_aeroApPlan'](70000,52000,54000,53000)
    assert plan['OK'] and plan['STAGE']==2 and plan['DV']<=390
    actual=flight['_aeroApEngine']()
    assert actual['THRUST']==20 and abs(actual['VE']-315*9.80665)<1e-9
    source=function_body(AERO,'phaseAerobrake')
    stage_at=source.index('aerobrakeApStageCoast(')
    forecast_at=source.index('aerobrakeApAssist(',stage_at)
    assert source.rfind('_aerobrakeSolarWait(',0,stage_at)>source.index('UNTIL SHIP:STATUS')
    assert stage_at<source.index('_aerobrakeSetEntryAlarm()',stage_at)<forecast_at
    assert 'STAGE.' not in mask(ASSIST) # Original live stage-change cutoff remains.
    assert 'STAGE:NUMBER <> control["STAGE"]' in ASSIST
    deps,_,_=dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    assert 'aerobrake_staging' in closure(['aerobrake'],deps)
    assert 'aerobrake_staging' not in closure(['return_setup'],deps)
    print('PASS: post-handoff finite forecast uses new wet mass/engine; phase stages only after warp release, refreshes KAC and plans anew, preserving powered stage-change cutoff and return-setup loading size')


if __name__=='__main__':
    check_two_handoffs()
    check_rejections()
    check_native_slot_modules()
    check_interruption_and_revalidation()
    check_fresh_forecast()
