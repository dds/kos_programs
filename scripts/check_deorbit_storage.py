"""Execute conditional orbital landing loads and their disabled-search path.

Source fixtures only; native KSM sizes and CPU storage fit require a game boot.
"""
import re
from types import SimpleNamespace as NS

from check_codebase import ROOT, closure, dependency_tables, function_body
from check_runtime_contracts import KList, run
from check_surface_return import read_settings


TYPE = (ROOT/'lib/mission_type.ks').read_text()
LAND = (ROOT/'lib/landing_deorbit.ks').read_text()
FLAGS = ('LANDING_AUTO_TARGET', 'LANDING_REQUIRE_SITE', 'LANDING_SITE_SCAN_ENABLE')


def flags(profile):
    # Use the real declarations/profile assignments, without evaluating
    # unrelated vehicle defaults or the rest of the generated mission.
    env = {}
    for declaration, source in (('GLOBAL', TYPE), ('SET', profile)):
        lines = '\n'.join(line for line in source.splitlines()
                          if re.match(rf'{declaration} (?:{"|".join(FLAGS)})\b', line))
        read_settings(lines, env, declaration)
    return env


def check_optional_dependency_closure():
    deps, phases, _ = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    retained = {'deorbit_targeting', 'deorbit_burn', 'landing_deorbit_lead',
                'landing_prediction', 'landing_stage_brake', 'vessel_hardware',
                'landing_roles', 'thrust_cutoff', 'landing_light',
                'landing_light_math', 'landing_radio'}
    optional = {'landing_site', 'landing_light_wait', 'landing_light_search'}
    for mission, expected in (('mun_target_science_return', set()),
                              ('minmus_economy_return', optional)):
        env = flags((ROOT/f'missions/RO9/{mission}.ks').read_text())
        env.update(bandKey='LAND_DEORBIT', SEQUENCE=KList(), LIST=lambda *xs:KList(xs))
        roots = run(function_body(TYPE, 'missionTypeConditionalRoots'), env)
        loaded = set(closure(phases['land_deorbit'] + roots, deps))
        assert retained <= loaded, retained-loaded
        assert loaded & optional == expected, (mission, loaded & optional)
        exports = '\n'.join((ROOT/f'lib/{name}.ks').read_text() for name in loaded)
        for symbol in ('executeDeorbitNode', 'landingDeorbitNodeReady',
                       'landingDeorbitNodeAccepted', 'landingLightNodeAllowed',
                       'landingPredictBrake', 'vesselLandingPrepareRoles', 'thrustCutoffOk'):
            assert re.search(rf'GLOBAL FUNCTION {symbol}\b', exports), (mission, symbol)
        if not expected:
            assert not re.search(r'GLOBAL FUNCTION (?:landingLitGroundTrack|selectScanSatLandingSite)\b', exports)
    env = flags('SET LANDING_REQUIRE_SITE TO 1.')
    env.update(bandKey='LAND_DEORBIT', SEQUENCE=KList(), LIST=lambda *xs:KList(xs))
    roots = run(function_body(TYPE, 'missionTypeConditionalRoots'), env)
    assert 'landing_site' in closure(roots, deps)
    # Flags must already exist when the core plans its conditional closure.
    assert 'mission_type' in closure(['core'], deps)
    libraries = '\n'.join(path.read_text() for path in (ROOT/'lib').glob('*.ks'))
    for name in FLAGS + ('LANDING_SITE_SCAN_RADIUS', 'LANDING_SITE_SCAN_STEP', 'LANDING_SITE_MAX_SLOPE'):
        assert len(re.findall(rf'GLOBAL {name} IS\b', libraries)) == 1, name
    print('PASS: actual fixed-site profile omits optional ground-track/search/wait/picker code; economy and required-site policies retain it; powered forecast, native admission, radio, staging and cutoff providers remain offline')


def check_disabled_picker_and_required_site():
    source = function_body(LAND, '_landingTargetedDeorbit')
    for enabled, required, expected in ((0,0,True), (0,1,False), (1,0,True)):
        calls = []
        env = dict(LANDING_SITE_SCAN_ENABLE=enabled, LANDING_REQUIRE_SITE=required,
                   LEXICON=lambda *xs:dict(zip(xs[::2],xs[1::2])),
                   CONFIG=NS(IPU=2000), LANDING_MIN_IPU=2000, _landingTargetPassUT=12345,
                   landingResolveTarget=lambda:dict(FOUND=True,LAT=-10.590,LNG=99.490,SOURCE='locked config'),
                   targetedDeorbitAt=lambda *xs:calls.append(('plan',xs)) or True)
        if enabled or required:
            env['selectScanSatLandingSite'] = lambda *xs:calls.append(('scan',xs)) or dict(FOUND=False)
        result = run(source,env)
        assert result is expected, (enabled,required,result)
        assert ('scan' in [row[0] for row in calls]) == bool(enabled or required)
        if expected:
            assert calls[-1] == ('plan',(-10.590,99.490,0,0,False,12345))
        else:
            assert all(row[0]!='plan' for row in calls)
    print('PASS: fixed-target planning executes without a picker symbol and keeps its coordinates/pass; required-site failure still prevents planning, and enabled scanning still runs')


def check_boot_planning_and_cleanup():
    boot = (ROOT/'lib/boot_lib.ks').read_text()
    deps, phases, _ = dependency_tables((ROOT/'lib/dependencies.ks').read_text())
    for automatic in (False,True):
        env = flags('SET LANDING_AUTO_TARGET TO '+str(int(automatic))+'.')
        env.update(SEQUENCE=KList(['LAND_DEORBIT']), LIBS=KList(), LIST=lambda *xs:KList(xs),
                   db='LAUNCH', SHIP=NS(STATUS='ORBITING'), stateGet=lambda *_:'LAND_DEORBIT',
                   stateSet=lambda *_:None, phaseSequenceEnsurePrelaunch=lambda seq:seq,
                   bootEnsureInitialPhase=lambda _:None, bootLibBandForPhase=lambda *_:'LAND_DEORBIT',
                   bootLibBandRoots=lambda _:KList(phases['land_deorbit']),
                   bootLibResolve=lambda roots:KList(closure(roots,deps)),
                   missionTypeCacheRoots=lambda _:KList(), missionExtraLibs=lambda:KList(),
                   missionAppendUnique=lambda dest,src:dest.extend(x for x in src if x not in dest))
        env['missionTypeConditionalRoots']=lambda band:run(
            function_body(TYPE,'missionTypeConditionalRoots'),dict(env,bandKey=band))
        wl = run(function_body(boot,'bootPlannedMissionLibs'),env)
        keep = {}
        def prune(path,names):
            keep[path]=list(names)
            return 0
        env.update(vn='RO9',wl=wl,missionVehicle='RO9',BOOT_CACHE_LIBS=KList(),
                   CORE=NS(TAG='',VOLUME=NS(FREESPACE=8510)),
                   bootLibArchiveOnly=lambda _:False, bootPruneDir=prune,
                   bootPruneMissionPlans=lambda *_:0,bootPruneLogs=lambda:0,EXISTS=lambda _:False)
        run(function_body(boot,'bootCleanup'),env)
        assert 'landing_light' in keep['1:/lib'] and 'landing_prediction' in keep['1:/lib']
        assert ('landing_light_wait' in keep['1:/lib']) is automatic
        assert ('landing_light_search' in keep['1:/lib']) is automatic
        assert 'landing_site' not in keep['1:/lib']
    print('PASS: actual boot planner passes conditional closure into actual cleanup; fixed-site boots release unused wait/search libraries while automatic boots retain them, with validation and forecast retained in both')


if __name__ == '__main__':
    check_optional_dependency_closure()
    check_disabled_picker_and_required_site()
    check_boot_planning_and_cleanup()
