"""Check generated return profiles across two simulated fresh boots.

Evaluates only SET/LOG serialization and scalar conditions from the source,
not flight dynamics or the kOS VM. Run: python3 scripts/check_surface_return.py
"""

import re
from pathlib import Path

from check_launch_and_staging import body, evaluate

ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / 'lib/return_setup.ks').read_text()
AERO = (ROOT / 'lib/aerobrake.ks').read_text()


def expression(text, env):
    text = text.replace(':CONTAINS', '.__contains__')
    text = text.replace('BODY:NAME:TOUPPER', 'BODY_NAME')
    text = re.sub(r'\bTRUE\b', 'True', text)
    text = re.sub(r'\bFALSE\b', 'False', text)
    text = text.replace('<>', '!=')
    return eval(text, {'__builtins__': {}, 'LIST': lambda *xs: list(xs),
                      'MAX': max, 'configLiteral': literal}, env)


def literal(value):
    if isinstance(value, list):
        return 'LIST(' + ', '.join(map(literal, value)) + ')'
    if isinstance(value, str):
        return '"' + value + '"'
    return str(value)


def read_settings(source, env, declaration='SET'):
    source = re.sub(r'//[^\n]*', '', source)
    verb = 'TO' if declaration == 'SET' else 'IS'
    pattern = rf'\b{declaration} (\w+) {verb} (.*?)\.(?=\s*(?:\n|$))'
    for match in re.finditer(pattern, source, re.S):
        env[match[1]] = expression(match[2], env)
    return env


def emit_profile(function, env):
    """Run the source's profile-writing block, with IO captured as text."""
    source = body(SETUP, function)
    source = source[source.index('LOCAL profilePath'):]
    source = source[:source.index('    stateSet("phase"')]
    if '    FOR key' in source:
        source = source[:source.index('    FOR key')]
    source = re.sub(r'//[^\n]*', '', source)
    # Split braces/newlines outside strings (including one-line IF blocks).
    chunks, start = [], 0
    for match in re.finditer(r'"[^"\n]*"|[{}\n]', source):
        if match[0].startswith('"'):
            continue
        if source[start:match.start()].strip():
            chunks.append(source[start:match.start()].strip())
        if match[0] in '{}':
            chunks.append(match[0])
        start = match.end()
    active = [True]
    output = []
    for chunk in chunks:
        if chunk == '{':
            continue
        if chunk == '}':
            active.pop()
        elif chunk.startswith('IF '):
            active.append(active[-1] and bool(expression(chunk[3:], env)))
        elif not active[-1]:
            continue
        elif chunk.startswith('LOCAL profilePath') or chunk == '_writeCoastAutomation(profilePath).':
            continue
        elif chunk.startswith('LOCAL '):
            match = re.fullmatch(r'LOCAL (\w+) IS (.*?)\.', chunk)
            assert match, chunk
            env[match[1]] = expression(match[2], env)
        else:
            match = re.fullmatch(r'LOG (.*?) TO profilePath\.', chunk)
            assert match, chunk
            output.append(expression(match[1], env))
    assert active == [True]
    return '\n'.join(output) + '\n'


def defaults():
    # Only declarations preceding the functions: no flight code is evaluated.
    return read_settings(SETUP[:SETUP.index('LOCAL FUNCTION')], {}, 'GLOBAL')


def check_profiles():
    for moon in ('mun', 'minmus'):
        initial = read_settings(
            (ROOT / f'missions/RO8/{moon}_landing_return.ks').read_text(), defaults())
        assert initial['SEQUENCE'][-2:] == ['LAND_ASSIST', 'SURFACE_RETURN_SETUP']
        assert len(initial['SEQUENCE']) == len(set(initial['SEQUENCE']))
        initial.update(BODY_NAME=moon.upper(),
                       PARKING_ALT=initial['SURFACE_RETURN_PARKING_ALT'],
                       LAUNCH_INCLINATION=initial['SURFACE_RETURN_INCLINATION'],
                       LAUNCH_AZIMUTH=90)
        surface_text = emit_profile('phaseSurfaceReturnSetup', initial)
        # Original landing profile/globals are gone after the reboot.
        surface = read_settings(surface_text, defaults())
        assert surface['SEQUENCE'] == ['PRELAUNCH', 'LAUNCH', 'PARK', 'RETURN_SETUP']
        assert surface['PARKING_ALT'] == 10000
        assert surface['RETURN_PE'] == 53000
        assert surface['RETURN_PE_TOLERANCE'] == 1000
        surface['targetPe'] = surface['RETURN_PE']
        home = read_settings(emit_profile('phaseReturnSetup', surface), {})
        assert home['SEQUENCE'] == ['ESCAPE', 'COAST', 'MCC', 'RETURN_TRIM',
                                    'AEROBRAKE', 'DESCENT', 'DONE']
        for key in ('ESCAPE_PE', 'CAPTURE_PE', 'REENTRY_PE', 'AEROBRAKE_PE'):
            assert home[key] == 53000, (moon, key, home)
        for key in ('MCC_AEROBRAKE_SAFE_PE_MIN', 'RETURN_TRIM_PE_MIN',
                    'AEROBRAKE_CORRECTION_PE_MIN', 'AEROBRAKE_BRAKE_PE_FLOOR'):
            assert home[key] == 52000, (moon, key)
        for key in ('MCC_AEROBRAKE_SAFE_PE_MAX', 'RETURN_TRIM_PE_MAX',
                    'AEROBRAKE_CORRECTION_PE_MAX'):
            assert home[key] == 54000, (moon, key)
        assert home['CAPTURE_INC'] == -1  # no paid equatorial plane change
        assert home['RETURN_TRIM'] is True
        assert home['RETURN_TRIM_DV_CAP'] == 20
        assert home['ESCAPE_KSC_TARGET'] == home['AEROBRAKE_PE_TARGETING'] == 1
        assert home['TARGET_LOCK'] == home['AEROBRAKE_TARGETING'] == 1
        assert home['TARGET_LAT'] == -0.0972 and home['TARGET_LNG'] == -74.5577
        assert home['TARGET_WAYPOINT'] == ''
        assert home['DESCENT_DECOUPLER_TAG'] == 'descent_decoupler'
        assert home['DESCENT_DECOUPLE_ALT'] == 50500
        assert home['DESCENT_CHUTES_TAG'] == 'descent_chutes'
        assert home['DESCENT_RELEASE_ALT'] == 38000
        assert home['AEROBRAKE_ARM_CHUTES'] == 1
        assert 'DESCENT_HEAT_SHIELD_DROP_ALT' not in home
        print(f'{moon}: surface ascent -> Kerbin return preserves shallow entry and KSC settings')

    legacy = defaults()
    legacy['targetPe'] = legacy['REENTRY_PE']
    home = read_settings(emit_profile('phaseReturnSetup', legacy), {})
    assert home['CAPTURE_PE'] == 30000
    assert home['CAPTURE_INC'] == 0
    assert 'AEROBRAKE_CORRECTION_PE_MIN' not in home
    assert 'AEROBRAKE_PE_TARGETING' not in home
    assert 'RETURN_TRIM' not in home
    print('legacy returns: shallow-entry corridor remains opt-in')


def check_site_corrections():
    predicate = re.search(r'RETURN (.*?)\.', body(AERO, '_aerobrakeCorrectionPeOk'), re.S)[1]
    for lower, upper in ((-1, -1), (52000, 54000), (52000, -1), (-1, 54000)):
        for pe in (-1000, 25000, 51999, 52000, 53000, 54000, 54001, 80000):
            actual = evaluate(predicate, pe=pe, AEROBRAKE_CORRECTION_PE_MIN=lower,
                              AEROBRAKE_CORRECTION_PE_MAX=upper)
            assert actual == ((lower < 0 or pe >= lower) and (upper < 0 or pe <= upper))
    targeting = body(AERO, '_aerobrakeReentryTargeting')
    assert 'IF _aerobrakeCorrectionPeOk(nd:ORBIT:PERIAPSIS)' in targeting
    guard = targeting.index('IF NOT _aerobrakeCorrectionPeOk(nd:ORBIT:PERIAPSIS)')
    burn = targeting.index('executeManeuver()')
    assert guard < burn and 'REMOVE nd.' in targeting[guard:burn]
    assert 'RETURN.' in targeting[guard:burn]
    print('impact targeting: corridor boundary fixtures and final burn guard passed')


def check_shallow_command():
    source = (ROOT / 'cmd/returnshallow.ks').read_text()
    assert source.index('bootPreamble().') < source.index('stateGet(')
    assert source.index('bootLibLoad("return_setup").') < source.index('SET RETURN_')
    for tag in ('descent_decoupler', 'descent_chutes'):
        assert f'SHIP:PARTSTAGGED("{tag}"):LENGTH = 0' in source
    command = read_settings(source, defaults())
    command['targetPe'] = command['RETURN_PE']
    # The generated profile must override RO6 hardware defaults after reboot.
    home = read_settings(emit_profile('phaseReturnSetup', command),
                         {'DESCENT_RELEASE_ALT': 10000,
                          'AEROBRAKE_BRAKE_PE_FLOOR': 51000,
                          'AEROBRAKE_DECOUPLE_TAG': ''})
    assert home['SEQUENCE'] == ['ESCAPE', 'COAST', 'MCC', 'RETURN_TRIM',
                                'AEROBRAKE', 'DESCENT', 'DONE']
    for key in ('ESCAPE_PE', 'CAPTURE_PE', 'REENTRY_PE', 'AEROBRAKE_PE'):
        assert home[key] == 53000
    for key in ('MCC_AEROBRAKE_SAFE_PE_MIN', 'RETURN_TRIM_PE_MIN',
                'AEROBRAKE_CORRECTION_PE_MIN', 'AEROBRAKE_BRAKE_PE_FLOOR'):
        assert home[key] == 52000
    for key in ('MCC_AEROBRAKE_SAFE_PE_MAX', 'RETURN_TRIM_PE_MAX',
                'AEROBRAKE_CORRECTION_PE_MAX'):
        assert home[key] == 54000
    assert home['CAPTURE_INC'] == -1
    assert home['RETURN_TRIM'] is True and home['RETURN_TRIM_DV_CAP'] == 20
    assert home['TARGET_LAT'] == -0.0972 and home['TARGET_LNG'] == -74.5577
    assert home['TARGET_LOCK'] == home['ESCAPE_KSC_TARGET'] == 1
    assert home['AEROBRAKE_TARGETING'] == home['AEROBRAKE_PE_TARGETING'] == 1
    assert home['AEROBRAKE_REENTRY_DIR'] == 'RETROGRADE'
    assert home['AEROBRAKE_ARM_CHUTES'] == 1
    assert home['AEROBRAKE_DECOUPLE_TAG'] == ''  # no entry-stage jettison
    assert home['DESCENT_DECOUPLER_TAG'] == 'descent_decoupler'
    assert home['DESCENT_CHUTES_TAG'] == 'descent_chutes'
    assert home['DESCENT_DECOUPLE_ALT'] == 6000
    assert home['DESCENT_FAIRING_TAG'] == 'none'  # no fairing wait before separation
    print('shallow command: fresh-boot profile preserves entry corridor and late stage separation')


def check_economy_profiles():
    for moon, reserve in (('mun', 1500), ('minmus', 550)):
        cfg = read_settings((ROOT / f'missions/RO8/{moon}_economy_return.ks').read_text(), defaults())
        assert cfg['MISSION_ID'] == f'{moon}_economy_return'
        assert cfg['LAUNCH_PLANE_MODE'] == 'BODY_ORBIT'
        assert cfg['CAPTURE_INC'] == cfg['CAPTURE_LAN'] == cfg['CAPTURE_AOP'] == -1
        assert cfg['CAPTURE_DIR'] == ''
        assert cfg['BPLANE_PE_ONLY'] == 1 and cfg['BPLANE_REQUIRE_PLANE'] == 0
        assert cfg['CAPTURE_PE'] == cfg['TARGET_AP'] == 15000
        assert 'SHAPE' not in cfg['SEQUENCE']
        assert len(cfg['SEQUENCE']) == len(set(cfg['SEQUENCE']))
        assert cfg['CAPTURE_RESERVE_DV'] == cfg['BPLANE_CAPTURE_MARGIN'] == reserve
        assert cfg['SCIENCE_OPS_HOLD'] == 0 and cfg['SCIENCE_SURVEY_POINTS'] == []
        assert cfg['TARGET_LAT'] == cfg['TARGET_LNG'] == 0
        assert cfg['LANDING_USE_WAYPOINTS'] == 0 and cfg['LANDING_AUTO_TARGET'] == 1
        cfg.update(BODY_NAME=moon.upper(), PARKING_ALT=cfg['SURFACE_RETURN_PARKING_ALT'],
                   LAUNCH_INCLINATION=cfg['SURFACE_RETURN_INCLINATION'], LAUNCH_AZIMUTH=90)
        surface = read_settings(emit_profile('phaseSurfaceReturnSetup', cfg), defaults())
        assert surface['LAUNCH_INCLINATION'] == 0 and surface['LAUNCH_AZIMUTH'] == 90
        assert surface['PARKING_ALT'] == 10000
        surface['targetPe'] = surface['RETURN_PE']
        # Fresh aerobrake defaults enable site targeting; the generated
        # economy profile must explicitly turn it off after every reboot.
        home = read_settings(emit_profile('phaseReturnSetup', surface),
                             {'AEROBRAKE_TARGETING': 1, 'ESCAPE_KSC_TARGET': 1})
        assert home['AEROBRAKE_TARGETING'] == home['ESCAPE_KSC_TARGET'] == 0
        assert 'RETURN_TRIM' not in home['SEQUENCE']
        assert home['CAPTURE_INC'] == -1
        assert home['REENTRY_PE'] == home['AEROBRAKE_PE'] == 53000
        assert home['MCC_AEROBRAKE_SAFE_PE_MIN'] == 52000
        assert home['MCC_AEROBRAKE_SAFE_PE_MAX'] == 54000
        assert home['AEROBRAKE_PE_TARGETING'] == 1  # Pe correction is still required.
        assert home['DESCENT_DECOUPLE_ALT'] == 6000
        assert home['DESCENT_DECOUPLER_TAG'] == 'descent_decoupler'
        assert home['DESCENT_CHUTES_TAG'] == 'descent_chutes'
        print(f'{moon} economy: free arrival plane, direct capture, east ascent and no KSC trim survive boots')

    landing = (ROOT / 'lib/landing_config.ks').read_text()
    resolver = body(landing, 'landingResolveTarget')
    named_gate = re.search(r'IF (LANDING_USE_WAYPOINTS > 0 AND TARGET_WAYPOINT <> "")', resolver)[1]
    for enabled in (0, 1):
        for named in ('', 'old polar contract'):
            assert evaluate(named_gate, LANDING_USE_WAYPOINTS=enabled,
                            TARGET_WAYPOINT=named) == bool(enabled and named)
    assert 'IF LANDING_USE_WAYPOINTS > 0 { SET selectedWp TO selectedWaypoint(). }' in resolver
    assert 'GLOBAL LANDING_USE_WAYPOINTS IS 1.' in landing
    # Locked auto-selected sites must still resolve with waypoints disabled.
    assert 'SET result["SOURCE"] TO "locked config"' in resolver
    print('landing target: economy ignores contract waypoints; default profiles keep waypoint selection')


def check_orbit_return():
    cfg = read_settings((ROOT / 'missions/RO8/mun_orbit_return.ks').read_text(), defaults())
    assert cfg['SEQUENCE'][-3:] == ['CAPTURE', 'SCIENCE_OPS', 'RETURN_SETUP']
    assert not set(cfg['SEQUENCE']) & {'LAND_DEORBIT', 'LAND_ASSIST', 'SURFACE_RETURN_SETUP', 'SHAPE'}
    assert cfg['CAPTURE_PE'] == cfg['TARGET_AP'] == 15000
    assert cfg['CAPTURE_INC'] == -1 and cfg['BPLANE_PE_ONLY'] == 1
    assert cfg['CAPTURE_MIN_PE'] == 13000 and cfg['CAPTURE_MAX_PE'] == 17000
    assert cfg['BPLANE_CAPTURE_MARGIN'] == cfg['CAPTURE_RESERVE_DV'] == 400
    assert cfg['SCIENCE_OPS_HOLD'] == 1 and cfg['SCIENCE_SURVEY_POINTS'] == []
    assert cfg['AUTO_TRANSMIT'] == 0
    # The real capture budget expressions must allow a representative
    # 900 m/s flight to capture while retaining departure/correction fuel.
    arrival = (ROOT / 'lib/arrival_bplane.ks').read_text()
    gate = body(arrival, 'bplaneCorrectionAllowed')
    needed = re.search(r'LOCAL needed IS (.*?)\.', gate, re.S)[1]
    from types import SimpleNamespace as NS
    for correction, capture, allowed in [(2, 300, True), (20, 480, True), (20, 481, False)]:
        cost = evaluate(needed, nd=NS(DELTAV=NS(MAG=correction)),
                        bplaneCaptureCost=lambda *_: capture, planned={'patch': None},
                        targetBody=None, BPLANE_CAPTURE_MARGIN=cfg['BPLANE_CAPTURE_MARGIN'])
        assert (cost <= 900) == allowed
    science = (ROOT / 'lib/science.ks').read_text()
    assert 'IF AUTO_TRANSMIT > 0' in body(science, '_runExperiment')
    assert 'SCI_AUTO_TRANSMIT' not in science
    phase = body(science, 'phaseScienceOps')
    assert phase.index('scienceRunAll()') < phase.index('IF SCIENCE_OPS_HOLD')
    assert phase.index('yieldToPrompt(). RETURN.') < phase.index('nextPhase(xferSeq)')
    cfg['targetPe'] = cfg['RETURN_PE']
    home = read_settings(emit_profile('phaseReturnSetup', cfg), {})
    assert home['REENTRY_PE'] == 53000 and home['CAPTURE_INC'] == -1
    assert home['AEROBRAKE_TARGETING'] == home['ESCAPE_KSC_TARGET'] == 0
    assert home['DESCENT_DECOUPLE_ALT'] == 6000
    assert home['DESCENT_CHUTES_TAG'] == 'descent_chutes'
    print('Mun orbital return: 900 m/s budget fixtures, science hold/storage and direct shallow return')


if __name__ == '__main__':
    check_profiles()
    check_site_corrections()
    check_shallow_command()
    check_economy_profiles()
    check_orbit_return()
