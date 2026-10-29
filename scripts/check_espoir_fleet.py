"""Espoir profile handoffs and airless impact control; not native flight tests."""
import re
from types import SimpleNamespace as NS

from check_codebase import ROOT, closure, dependency_tables, function_body
from check_minmus_kolniya import execute
from check_runtime_contracts import KList, KString
from check_surface_return import read_settings

SETUP = (ROOT/'lib/duna_ike_setup.ks').read_text()
IMPACT = (ROOT/'lib/science_impact.ks').read_text()
ENTRY = (ROOT/'lib/science_entry.ks').read_text()
CONFIG = (ROOT/'lib/config.ks').read_text()


class Text(KString):
    def ISTYPE(self, kind): return kind == 'String'
    def __add__(self, other): return Text(str(self)+str(other))
    def __radd__(self, other): return Text(str(other)+str(self))


class Number(float):
    def ISTYPE(self, kind): return kind == 'Scalar'
    def __radd__(self, other):
        if isinstance(other, str): return Text(other+str(self))
        return float.__radd__(self, other)


class Items(KList):
    def ISTYPE(self, kind): return kind == 'List'
    def JOIN(self, separator): return Text(separator.join(map(str, self)))


class Map(dict):
    def HASKEY(self, key): return dict.__contains__(self, str(key))
    def __getitem__(self, key): return dict.__getitem__(self, str(key))
    LENGTH = property(len)
    KEYS = property(lambda self: Items(Text(key) for key in self))
    def ISTYPE(self, kind): return kind == 'Lexicon'


def native(value):
    if isinstance(value, dict): return Map({key:native(item) for key,item in value.items()})
    if isinstance(value, list): return Items(native(item) for item in value)
    if isinstance(value, str): return Text(value)
    if isinstance(value, (int, float)): return Number(value)
    return value


def literal(value):
    return execute(function_body(CONFIG, 'configLiteral'),
                   dict(raw=native(value), LIST=lambda:Items(), CHAR=lambda n:Text(chr(int(n))),
                        configLiteral=literal))


def profile(name):
    return native(read_settings((ROOT/f'missions/Espoir/{name}.ks').read_text(), {}))


def run(source, name, env):
    code = function_body(source, name)
    code = re.sub(r'WAIT UNTIL [^.]+\.', 'fixture_settled().', code)
    code = re.sub(r'LOG (.*?) TO DI_PROFILE_PATH\.', r'capture_log(\1).', code)
    code = code.replace('REBOOT.', 'fixture_reboot().').replace('REMOVE nd.', 'remove_node(nd).')
    code = code.replace('BRAKES ON.', 'fixture_brakes().')
    return execute(code, env)


def check_profiles_and_dependencies():
    deps, phases, bands = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for name in ('duna_orbital_surveyor','ike_orbital_surveyor','ike_impactor','duna_impactor'):
        cfg = profile(name)
        assert cfg['MISSION_ID'] == name and cfg['TARGET_'] == 'DUNA'
        assert cfg['MISSION_TYPE'] == 'interplanetary' and cfg['PARKING_ALT'] == 85000
        assert cfg['LAUNCH_INCLINATION'] == 0 and cfg['LAUNCH_PLANE_MODE'] == 'INTERPLANETARY'
        legs = [cfg]
        if name.startswith('ike_'):
            assert cfg['CAPTURE_PE'] > 50000 and cfg['TARGET_AP'] == 2880000
            assert cfg['SEQUENCE'][-2:] == ['CAPTURE','IKE_SETUP']
            leg = cfg['IKE_MISSION_SETTINGS']
            assert leg['MISSION_ID'] != name
            assert not (ROOT/f"missions/Espoir/{leg['MISSION_ID']}.ks").exists()
            legs.append(dict(leg, SEQUENCE=cfg['IKE_FLYBY_SEQUENCE']))
        for leg in legs:
            seq = leg['SEQUENCE']
            assert len(seq) == len(set(seq))
            assert not set(seq) & {'DUNA_AEROCAPTURE','DUNA_ENTRY_SETUP','FLYBY','RETURN_SETUP'}
            for phase in seq:
                assert phase.lower() in phases and closure(phases[phase.lower()], deps)
            if 'SCANSAT_OPS' in seq:
                assert leg['SHAPE_INC'] == leg['CAPTURE_INC'] == 90
                assert leg['SHAPE_PE'] == leg['SHAPE_AP']
                assert leg['SCANSAT_DECOUPLER_TAG'] == ''
                assert leg['SCANSAT_AUTO_DEORBIT'] == leg['SCANSAT_DISPOSE_CARRIER'] == 0
                assert leg['SCANSAT_POWER_LOW'] < leg['SCANSAT_POWER_RESUME']
        if name == 'duna_impactor':
            assert 'CAPTURE' not in cfg['SEQUENCE'] and cfg['SCIENCE_ENTRY_MOON'] == ''
            assert 0 < cfg['CAPTURE_PE']-cfg['BPLANE_PE_TOL']
            assert cfg['CAPTURE_PE']+cfg['BPLANE_PE_TOL'] < 50000
        if name == 'ike_impactor':
            assert legs[-1]['SEQUENCE'][-3:] == ['CAPTURE','SCIENCE_IMPACT','DONE']
            assert legs[-1]['SCIENCE_IMPACT_PE'] < 0
    assert bands['science_impact'] == ['science_impact']
    assert {'science_flight','science_entry','maneuver_plan','thrust_cutoff'} <= closure(['science_impact'],deps)
    assert 'science_impact' not in closure(['science_entry'],deps)
    bindings = function_body((ROOT/'lib/dependencies.ks').read_text(), 'dependencyBindPhase')
    assert 'phaseScienceImpact@' in bindings
    print('PASS: four distinct launch profiles and generated Ike legs resolve; polar mappers retain hardware, impacts have no accidental flyby/return or atmospheric-capture route')


def setup_fixture(name='ike_orbital_surveyor'):
    cfg = read_settings(SETUP.split('LOCAL DUNA_ATM_HEIGHT',1)[0], {}, 'GLOBAL')
    cfg.update(profile(name))
    cfg = native(cfg)
    saved = {'vehicle':Text('Espoir'), 'mission_id':Text(name), 'phase':Text('IKE_SETUP')}
    events, output = [], []
    orbit = NS(ECCENTRICITY=.8,HASNEXTPATCH=False)
    ship = NS(BODY=NS(NAME='DUNA'),STATUS='ORBITING',PERIAPSIS=85000,ORBIT=orbit,THRUST=0,
              CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0))
    env = dict(cfg,SHIP=ship,ABORT=False,HASNODE=False,TIME=NS(SECONDS=100),ROUND=round,
               LIST=lambda *xs:Items(xs),_diBodyName=lambda:'DUNA',_diAtmHeight=lambda:50000,
               stateGet=lambda key,default='':saved.get(key,default),
               stateSet=lambda key,value:saved.__setitem__(key,value),
               missionOverrideClear=lambda:events.append('clear-overrides'),
               missionProfileBegin=lambda *args:events.append(('profile',args)) or 'local.ks',
               configLiteral=literal,capture_log=output.append,
               _diArchiveLog=lambda:events.append('archive'),
               _diClearLibCache=lambda:events.append('clear-derived-cache'),
               _diHold=lambda *args:events.append(('hold',args)),
               fixture_wait=lambda delay:None,fixture_reboot=lambda:events.append('reboot'))
    # Execute both actual persistence helpers, including legacy Duna config.
    for field in re.findall(r'configLiteral\((\w+)\)',function_body(SETUP,'_diPersistCoastAutomation')):
        env.setdefault(field, 1)
    env['_diPersistCoastAutomation'] = lambda:run(SETUP,'_diPersistCoastAutomation',env)
    env['_diPersistDunaEntryCfg'] = lambda:run(SETUP,'_diPersistDunaEntryCfg',env)
    return env, saved, events, output


def check_ike_handoff_roundtrip_and_legacy():
    for name in ('ike_orbital_surveyor','ike_impactor'):
        env,saved,events,output = setup_fixture(name)
        run(SETUP,'phaseIkeSetup',env)
        assert saved['target'] == 'IKE' and saved['phase'] == 'XING'
        assert events[-1] == 'reboot' and events.count('reboot') == 1
        # Two completely fresh boots see only generated SET lines, not Duna globals.
        for boot in range(2):
            fresh = native(read_settings('\n'.join(output), {}))
            for key,value in env['IKE_MISSION_SETTINGS'].items():
                assert fresh[key] == value,(key,fresh[key],value)
            assert fresh['TARGET_'] == fresh['BPLANE_TARGET'] == 'IKE'
            assert fresh['SEQUENCE'] == env['IKE_FLYBY_SEQUENCE']
            assert fresh['MISSION_TYPE'] == saved['mission_type'] == 'moon_operations'
            assert fresh['PAYLOADS'] == saved['payloads']
            assert fresh['COAST_AUTO_WARP'] == 1
            assert fresh['CAPTURE_MIN_PE'] >= 20000
            assert fresh['CAPTURE_RESERVE_DV'] > 0
    env,saved,events,output = setup_fixture()
    env['IKE_MISSION_SETTINGS'] = Map()
    run(SETUP,'phaseIkeSetup',env)
    fresh = read_settings('\n'.join(output), {})
    assert fresh['MISSION_ID'] == 'duna_ike_flyby' and fresh['PAYLOADS'] == ['SCISAT']
    assert 'DUNA_ENTRY_SEQUENCE' in fresh and events[-1] == 'reboot'
    print('PASS: actual Ike handoff and recursive serializer preserve identity, payload, orbit, scan/impact config and budgets across fresh boots; empty settings retain the legacy flyby/Duna-entry recipe')


def check_ike_handoff_guards():
    for fault in ('abort','node','patch','pe','ecc','thrust','raw','pilot','burn','identity','settings','sequence','body','status'):
        env,saved,events,output = setup_fixture()
        if fault == 'abort':env['ABORT'] = True
        if fault == 'node':env['HASNODE'] = True
        if fault == 'patch':env['SHIP'].ORBIT.HASNEXTPATCH = True
        if fault == 'pe':env['SHIP'].PERIAPSIS = 40000
        if fault == 'ecc':env['SHIP'].ORBIT.ECCENTRICITY = float('nan')
        if fault == 'thrust':env['SHIP'].THRUST = .1
        if fault == 'raw':env['SHIP'].CONTROL.MAINTHROTTLE = .1
        if fault == 'pilot':env['SHIP'].CONTROL.PILOTMAINTHROTTLE = .1
        if fault == 'burn':saved.update(burn_pending='true',burn_started='true')
        if fault == 'identity':saved['vehicle'] = ''
        if fault == 'settings':env['IKE_MISSION_SETTINGS'].pop('MISSION_ID')
        if fault == 'sequence':env['IKE_FLYBY_SEQUENCE'] = Items(['XING','DONE'])
        if fault == 'body':env['_diBodyName'] = lambda:'IKE'
        if fault == 'status':env['SHIP'].STATUS = 'SUB_ORBITAL'
        before = saved.copy()
        run(SETUP,'phaseIkeSetup',env)
        assert saved == before and not output and len(events) == 1 and events[0][0] == 'hold',fault
    print('PASS: unsafe/wrong-body/bad-config Ike handoffs leave state, nodes, overrides and profile untouched')


def impact_fixture():
    primary = NS(NAME='IKE',RADIUS=130000,ATM=NS(EXISTS=False))
    ship = NS(BODY=primary,PERIAPSIS=-1000,ALTITUDE=30000,VERTICALSPEED=-100,
              STATUS='SUB_ORBITAL',ORBIT=NS(ECCENTRICITY=.8,HASNEXTPATCH=False,PERIOD=3000),
              THRUST=0,CONTROL=NS(MAINTHROTTLE=0,PILOTMAINTHROTTLE=0),DELTAV=NS(VACUUM=400))
    events, saved = [], {'mission_id':'ike_impactor_ops'}
    env = dict(SHIP=ship,primary=primary,ABORT=False,HASNODE=False,TIME=NS(SECONDS=100),
               WARP=0,SAS=True,SCIENCE_IMPACT_PE=-1000,SCIENCE_IMPACT_DV_CAP=150,
               SCIENCE_ENTRY_BANDS=Map(IKE=Items([50000,0])),SCIENCE_ENTRY_MIN_EC=.05,
               ADDONS=NS(SCANSAT=NS(AVAILABLE=False)),HOMECONNECTION=NS(ISCONNECTED=True),
               missionTargetBody=lambda:primary,stateGet=lambda key,default='':saved.get(key,default),
               aerobrakeApEntryEta=lambda height:200 if height == 0 else 0,
               shipPowerFraction=lambda:1,thrustCutoffOk=lambda:events.append('cutoff') or True,
               kacEnsureAlarm=lambda *args:events.append('alarm') or 'impact-alarm',
               DELETEALARM=lambda alarm:events.append(('delete',alarm)),
               fixture_settled=lambda:None,fixture_unlock=lambda:events.append('unlock'),
               fixture_lock=lambda value:events.append(('lock',value)),fixture_brakes=lambda:events.append('brakes'),
               _scienceImpactHold=lambda why:events.append(('hold',why)),
               nextPhase=lambda *_:events.append('advance'),xferSeq=Items(['SCIENCE_IMPACT','DONE']))
    def wait(seconds):
        env['TIME'].SECONDS += seconds
        env['ABORT'] = True
    env.update(fixture_wait=wait,
               scienceEntryContext=lambda:run(ENTRY,'scienceEntryContext',env),
               scienceFlightPulse=lambda *args:events.append(('sample',args[0])),
               _scienceImpactDeorbit=lambda:run(IMPACT,'_scienceImpactDeorbit',env),
               scienceEntryWait=lambda wake:events.append(('wait',wake)) or wait(wake-100))
    return env,saved,events


def check_airless_deorbit_admission():
    for fault in ('','node-pe','dv','fuel','nan','abort','execution','late','flown-pe','patch'):
        env,saved,events = impact_fixture()
        ship = env['SHIP'];ship.PERIAPSIS = 25000;ship.STATUS = 'ORBITING'
        node = NS(TIME=110,ORBIT=NS(PERIAPSIS=-1000,BODY=ship.BODY),DELTAV=NS(MAG=30))
        def plan(pe):events.append(('plan',pe));env['HASNODE']=True;return node
        def remove(nd):assert nd is node;events.append('remove');env['HASNODE']=False
        def burn():
            events.append('burn')
            if fault == 'execution':return False
            ship.PERIAPSIS = 100 if fault == 'flown-pe' else -1000
            ship.ORBIT.HASNEXTPATCH = fault == 'patch'
            env['HASNODE'] = False
            return True
        env.update(planLowerPe=plan,remove_node=remove,executeManeuver=burn,fixture_wait=lambda *_:None)
        if fault == 'node-pe':node.ORBIT.PERIAPSIS=10
        if fault == 'dv':node.DELTAV.MAG=151
        if fault == 'fuel':ship.DELTAV.VACUUM=20
        if fault == 'nan':node.DELTAV.MAG=float('nan')
        if fault == 'abort':env['ABORT']=True
        if fault == 'late':ship.ORBIT.PERIOD=1
        ok = run(IMPACT,'_scienceImpactDeorbit',env)
        assert bool(ok) == (not fault),fault
        assert node.TIME >= 160 if fault != 'late' else node.TIME < 160
        if fault in ('node-pe','dv','fuel','nan','abort','late'):
            assert 'remove' in events and 'burn' not in events
        elif fault:
            assert 'burn' in events and 'remove' not in events
        else:assert events[-1] == 'cutoff'
    env,saved,events=impact_fixture()
    assert run(IMPACT,'_scienceImpactDeorbit',env) and not events
    print('PASS: airless deorbit uses the native node, lead, cap/fuel and physical cutoff; invalid own nodes removed, executor failures retained, and a flown impact course never gets a second burn')


def check_airless_resident_science_and_guards():
    for fault in ('','abort','node','burn','thrust','raw','pilot','body','atmosphere','bad-pe','bad-ec','bands','escape','no-impact','surface','coast'):
        env,saved,events = impact_fixture()
        ship=env['SHIP']
        if fault=='abort':env['ABORT']=True
        if fault=='node':env['HASNODE']=True
        if fault=='burn':saved.update(burn_pending='true',burn_started='true')
        if fault=='thrust':ship.THRUST=.1
        if fault=='raw':ship.CONTROL.MAINTHROTTLE=.1
        if fault=='pilot':ship.CONTROL.PILOTMAINTHROTTLE=.1
        if fault=='body':env['missionTargetBody']=lambda:NS(NAME='DUNA',ATM=NS(EXISTS=True))
        if fault=='atmosphere':ship.BODY.ATM.EXISTS=True
        if fault=='bad-pe':env['SCIENCE_IMPACT_PE']=float('nan')
        if fault=='bad-ec':env['SCIENCE_ENTRY_MIN_EC']=1
        if fault=='bands':env['SCIENCE_ENTRY_BANDS']['IKE']=Items([0])
        if fault=='escape':ship.ORBIT.HASNEXTPATCH=True
        if fault=='no-impact':env['aerobrakeApEntryEta']=lambda *_:-1
        if fault=='surface':
            ship.STATUS='LANDED'
            env['fixture_wait']=lambda seconds:setattr(env['TIME'],'SECONDS',env['TIME'].SECONDS+seconds)
        if fault=='coast':
            ship.ALTITUDE=100000
            env['aerobrakeApEntryEta']=lambda height:600 if height==0 else 300
        run(IMPACT,'phaseScienceImpact',env)
        if fault in ('','coast','surface'):
            assert 'alarm' in events and ('delete','impact-alarm') in events
            assert any(isinstance(e,tuple) and e[0]=='sample' for e in events)
            assert not any(isinstance(e,tuple) and e[0]=='hold' for e in events)
            if fault=='surface':assert 'advance' in events and env['TIME'].SECONDS==160
            else:assert 'advance' not in events
            if fault=='coast':
                assert ('wait',400) in events
                assert events.index('alarm') < events.index(('wait',400))
            elif not fault:assert ('lock','LOCK STEERING TO SHIP:SRFRETROGRADE') in events
        elif fault=='abort':assert not events
        else:
            assert any(isinstance(e,tuple) and e[0]=='hold' for e in events),fault
            assert 'advance' not in events and 'alarm' not in events
        assert env['WARP']==0
    print('PASS: resident impact phase samples at1x near terrain, owns KAC before distant solar waits, cleans alarms on Abort, advances only on survived surface, and holds on foreign nodes/burns, invalid body/config or missed impact')


if __name__ == '__main__':
    check_profiles_and_dependencies()
    check_ike_handoff_roundtrip_and_legacy()
    check_ike_handoff_guards()
    check_airless_deorbit_admission()
    check_airless_resident_science_and_guards()
