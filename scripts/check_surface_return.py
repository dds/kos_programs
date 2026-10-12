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


if __name__ == '__main__':
    check_profiles()
    check_site_corrections()
