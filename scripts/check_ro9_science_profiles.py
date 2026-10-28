"""New satellite windows and targeted Mun return; source/math checks, not flight."""
import math
import re

from check_codebase import ROOT, dependency_tables, closure, function_body
from check_surface_return import read_settings, defaults, emit_profile, expression


def profile(name):
    return read_settings((ROOT / ('missions/RO9/' + name + '.ks')).read_text(), {})


def check_satellite_windows():
    geo = profile('kerbin_geostationary_satellite')
    polar = profile('kerbin_sunsync_satellite')
    medium = profile('kerbin_semisynchronous_satellite')
    assert geo['SHAPE_AP'] == geo['SHAPE_PE'] == 2863334 and geo['SHAPE_INC'] == 0
    assert geo['SHAPE_LAN'] == geo['SHAPE_AOP'] == -1
    assert 96 < polar['SHAPE_INC'] - polar['SHAPE_ANG_TOL']
    assert polar['SHAPE_INC'] + polar['SHAPE_ANG_TOL'] < 102
    assert 500000 < polar['SHAPE_PE'] - polar['SHAPE_ALT_TOL']
    assert polar['SHAPE_AP'] + polar['SHAPE_ALT_TOL'] < 900000
    radius, mu = 600000, 3.5316e12
    for error in (-medium['SHAPE_ALT_TOL'], medium['SHAPE_ALT_TOL']):
        a = radius + medium['SHAPE_AP'] + error
        period = 2 * math.pi * math.sqrt(a**3 / mu)
        assert 10343 < period < 11205, period
    assert 50 < medium['SHAPE_INC'] - medium['SHAPE_ANG_TOL']
    assert medium['SHAPE_INC'] + medium['SHAPE_ANG_TOL'] < 60
    assert medium['SHAPE_ALT_TOL'] / (radius + medium['SHAPE_AP']) < .02
    for cfg in (geo, polar, medium):
        assert cfg['PARKING_ALT']>=85000 # SHAPE retains Kerbin's80km floor.
        assert cfg['LAUNCH_INCLINATION'] == cfg['SHAPE_INC']
        assert cfg['LAUNCH_PLANE_MODE'] == '' and cfg['CAPTURE_LAN'] == -1
        assert 'XING' not in cfg['SEQUENCE'] and cfg['AUTO_TRANSMIT'] == cfg['SCIENCE_OPS_HOLD'] == 1
        assert cfg['SHAPE_DV_CAP'] > 0 and cfg['SHAPE_TOTAL_DV_CAP'] > cfg['SHAPE_DV_CAP']
        assert cfg['SHAPE_RESERVE_DV'] > 0
    print('PASS: satellite targets and worst accepted apsis/angle errors remain inside the supplied altitude/inclination/eccentricity/period windows; launch planes match, no unneeded transfer or undefined LAN/AoP burns')


def check_minmus_orbit_and_bindings():
    cfg = profile('minmus_elliptical_satellite')
    assert [cfg['SHAPE_' + key] for key in ('PE','AP','INC','LAN','AOP')] == [465764,1041045,21.6,255.5,157.3]
    assert cfg['CAPTURE_PE'] == cfg['TARGET_PE'] == cfg['SHAPE_PE']
    assert cfg['TARGET_AP'] == cfg['SHAPE_AP'] and cfg['CAPTURE_INC'] == cfg['SHAPE_INC']
    assert cfg['BPLANE_REQUIRE_PLANE'] == 1 and cfg['SHAPE_BURN_TOLERANCE'] == .001
    assert cfg['SEQUENCE'][-4:] == ['CAPTURE','SHAPE','SCIENCE_OPS','DONE']
    deps, phases, _ = dependency_tables((ROOT / 'lib/dependencies.ks').read_text())
    for name in ('kerbin_geostationary_satellite','kerbin_sunsync_satellite',
                 'kerbin_semisynchronous_satellite','minmus_elliptical_satellite','mun_target_science_return'):
        cfg = profile(name)
        assert cfg['MISSION_ID'] == name and len(cfg['SEQUENCE']) == len(set(cfg['SEQUENCE']))
        for phase in cfg['SEQUENCE']:
            assert phase.lower() in phases and closure(phases[phase.lower()], deps), (name, phase)
    print('PASS: exact Minmus ellipse/plane/AoP reaches science through CAPTURE/SHAPE; all five profiles use existing bound phases and separate IDs, without any mission activation')


def check_targeted_mun_return():
    cfg = profile('mun_target_science_return')
    assert (cfg['TARGET_LAT'], cfg['TARGET_LNG']) == (-10.590,99.490)
    assert cfg['TARGET_LOCK'] == 1 and cfg['LANDING_FLEXIBLE_SITE'] == cfg['LANDING_AUTO_TARGET'] == cfg['LANDING_USE_WAYPOINTS'] == 0
    assert cfg['CAPTURE_INC'] - cfg['BPLANE_ANG_TOL'] > abs(cfg['TARGET_LAT'])
    assert cfg['TARGET_AP'] == cfg['CAPTURE_PE'] == 15000
    assert cfg['LANDING_POWERED_LEAD'] == cfg['LANDING_STAGE_BRAKE_CREDIT'] == cfg['LANDING_ECONOMY_BRAKE'] == 1
    assert cfg['TERRAIN_CHECK_RADIUS'] == 20 and cfg['LANDING_SITE_MAX_SLOPE'] == 5
    assert cfg['SEQUENCE'][-4:] == ['LAND_DEORBIT','LAND_ASSIST','SCIENCE_OPS','SURFACE_RETURN_SETUP']
    assert cfg['AUTO_TRANSMIT'] == cfg['SCIENCE_OPS_HOLD'] == 0
    settings = read_settings((ROOT/'lib/aerobrake_config.ks').read_text(), defaults(), 'GLOBAL')
    settings = read_settings((ROOT/'craft/RO9.ks').read_text().split('applyKnownMissionState')[0], settings)
    settings.update(cfg, BODY_NAME='MUN', PARKING_ALT=10000,
                                          LAUNCH_INCLINATION=0, LAUNCH_AZIMUTH=90)
    writer = function_body((ROOT/'lib/return_setup.ks').read_text(), '_writeCoastAutomation')
    rows = re.findall(r'LOG ("SET AEROBRAKE_AP_.*?) TO profilePath\.', writer)
    def automation(values):
        return '\n'.join(expression(row, values) for row in rows)
    surface = read_settings(emit_profile('phaseSurfaceReturnSetup',settings) + automation(settings),defaults())
    surface.update(BODY_NAME='MUN', targetPe=surface['RETURN_PE'])
    home = read_settings(emit_profile('phaseReturnSetup',surface) + automation(surface),{})
    assert home['SEQUENCE'] == ['ESCAPE','COAST','MCC','AEROBRAKE','DESCENT','DONE']
    assert home['ESCAPE_PE'] == home['AEROBRAKE_PE'] == 53000 and home['ESCAPE_KSC_TARGET'] == 0
    assert home['AEROBRAKE_AP_RESERVE_DV'] >= 10 and home['AEROBRAKE_AP_BURN'] == 1
    print('PASS: reachable fixed Mun site keeps local terrain/landing limits, takes surface science once, and serializes the existing53km assisted Kerbin return without hops/polar surveys/KSC detours')


if __name__ == '__main__':
    check_satellite_windows()
    check_minmus_orbit_and_bindings()
    check_targeted_mun_return()
