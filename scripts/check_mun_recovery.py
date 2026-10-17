"""Offline source-expression checks; not a kOS VM or KSP flight simulator.

Run: python3 -B scripts/check_mun_recovery.py
"""
import math
import re
from pathlib import Path
from types import SimpleNamespace as NS

from check_launch_and_staging import body, evaluate
from check_surface_return import read_settings

ROOT = Path(__file__).resolve().parents[1]
ARRIVAL = (ROOT / 'lib/arrival_bplane.ks').read_text()
CAPTURE = (ROOT / 'lib/capture.ks').read_text()
PROFILE = read_settings((ROOT / 'missions/RO8/mun_capture_recovery.ks').read_text(), {})


def check_solver():
    # Run the current three-axis source, sharing the interpreter harness
    # with the normal-dominated Pe recovery fixtures.
    from check_arrival_pe_recovery import solve as solve_source

    def solve(patch, cap):
        result, _, _ = solve_source(lambda nd: patch(nd.PROGRADE, nd.RADIALOUT), cap)
        if result == 0:
            return None
        return result.PROGRADE, result.RADIALOUT, patch(result.PROGRADE, result.RADIALOUT)

    # Independent hyperbolic impact-parameter -> periapsis relation.
    mu, radius, vinf = 6.5138398e10, 200000., 300.
    initial_rp = radius + 742000
    initial_b = math.sqrt(initial_rp**2 + 2*mu*initial_rp/vinf**2)
    fixtures = 0
    for rotation in (0, .3, 1.5, 2.7, 4.1):
        def patch(pro, radial):
            impact = initial_b + 45000*(math.cos(rotation)*pro + math.sin(rotation)*radial)
            # Synthetic local direct-encounter domain, including lost trials.
            if abs(impact) > initial_b + 100 or abs(impact) < 1000:
                return None
            return math.sqrt((mu/vinf**2)**2 + impact**2) - mu/vinf**2 - radius
        result = solve(patch, 50)
        assert result is not None
        pro, radial, pe = result
        assert abs(pe - 15000) <= 2000
        assert math.hypot(pro, radial) < 50
        assert solve(patch, .5) is None  # Cannot buy the required correction.
        fixtures += 1
    assert solve(lambda *_: None, 50) is None
    assert solve(lambda *_: 742000, 50) is None  # No control authority.
    assert solve(lambda *_: 15000, 50) == (0., 0., 15000)
    # Old planning accepted the edge, then the executor could swallow
    # a <0.05 m/s retry while the real orbit remained below 13 km.
    result = solve(lambda pro, radial: 12900 + pro * 50000, 20)
    assert result is not None and abs(result[2] - 15000) <= 500
    assert 0 < math.hypot(*result[:2]) < .05
    print(f'PASS: {fixtures} nonlinear Pe solves, lost trial patches, exhausted budgets and zero authority')


def check_fuel_and_capture():
    gate = body(ARRIVAL, 'bplaneCorrectionAllowed')
    needed = re.search(r'LOCAL needed IS (.*?)\.', gate, re.S)[1]
    for correction, capture, fuel, allowed in [
        (25, 300, 899, True), (50, 799, 899, True),
        (50, 800, 899, False), (10, 300, 0, False)]:
        env = dict(nd=NS(DELTAV=NS(MAG=correction)), targetBody=None,
                   planned={'patch': object()}, bplaneCaptureCost=lambda *_: capture,
                   BPLANE_CAPTURE_MARGIN=PROFILE['BPLANE_CAPTURE_MARGIN'])
        assert (evaluate(needed, **env) <= fuel) == allowed
    phase = body(CAPTURE, 'phaseCapture')
    guard = re.search(r'IF (nd:DELTAV:MAG \+ CAPTURE_RESERVE_DV.*?) \{', phase)[1]
    for cost, fuel, reject in [(300, 849, False), (800, 849, True), (799, 849, False)]:
        assert evaluate(guard, nd=NS(DELTAV=NS(MAG=cost)),
                        CAPTURE_RESERVE_DV=50, SHIP=NS(DELTAV=NS(VACUUM=fuel))) == reject
    corridor = re.search(r'IF (\(CAPTURE_MIN_PE.*?CAPTURE_MAX_PE\)) \{', phase, re.S)[1]
    for pe, reject in [(742000, True), (15000, False), (13000, False), (17000, False), (-1, True)]:
        assert evaluate(corridor, CAPTURE_MIN_PE=13000, CAPTURE_MAX_PE=17000,
                        SHIP=NS(PERIAPSIS=pe)) == reject
    bound = re.search(r'IF (CAPTURE_ACCEPT_BOUND.*?SOIRADIUS) \{', phase, re.S)[1]
    for ecc, pe, ap, accept in [(.2,15000,100000,True),(1.2,15000,-1,False),
                                (.8,-100,100000,False),(.99,15000,3000000,False)]:
        assert evaluate(bound, CAPTURE_ACCEPT_BOUND=1, CAPTURE_MIN_PE=13000,
                        SHIP=NS(ORBIT=NS(ECCENTRICITY=ecc), PERIAPSIS=pe, APOAPSIS=ap),
                        target=NS(SOIRADIUS=2400000)) == accept
    print('PASS: reported 899 m/s recovery affordability, capture recheck, Pe corridor and bound-orbit resume')


def check_resume_and_handoff():
    assert PROFILE['SEQUENCE'] == ['BPLANE', 'COAST_1HALF', 'REFINE_BPLANE',
                                   'COAST_2HALF', 'CAPTURE', 'SHAPE', 'SCIENCE_OPS',
                                   'LAND_DEORBIT', 'LAND_ASSIST', 'SURFACE_RETURN_SETUP']
    assert PROFILE['CAPTURE_DIR'] == 'POLAR' and PROFILE['CAPTURE_INC'] == 90
    assert PROFILE['BPLANE_PE_ONLY'] == 0 and PROFILE['BPLANE_REQUIRE_PLANE'] == 1
    assert PROFILE['BPLANE_TRIM_RESERVE_DV'] == -1
    assert PROFILE['BPLANE_MAX_ARRIVAL_SHIFT'] == -1
    assert PROFILE['BPLANE_MAX_CAPTURE_DV_INCREASE'] == -1
    assert PROFILE['BPLANE_TRIM_TOTAL_DV_CAP'] == 160
    assert PROFILE['BPLANE_DV_CAP'] == PROFILE['BPLANE_TRIM_DV_CAP'] == 150
    assert 'GLOBAL BPLANE_PE_ONLY IS 0.' in ARRIVAL
    planner = body(ARRIVAL, 'planBplaneCorrection')
    assert planner.index('_bplanePlanPeOnly(') < planner.index('measureArrival(')
    resume = body(ARRIVAL, '_bplaneExistingNodeAcceptable')
    assert resume.index('IF BPLANE_PE_ONLY <> 0') < resume.index('bplaneCorrectionAllowed(')
    for name in ('phaseBplane', 'phaseRefineBplane'):
        phase = body(ARRIVAL, name)
        assert phase.index('_bplaneClearCoastTimes()') < phase.index('_bplaneExecuteCorrection()')
        assert phase.index('_bplaneFinishPeRecovery(') < phase.index('_bplaneSafeEncounter(')
    finish = body(ARRIVAL, '_bplaneFinishPeRecovery')
    assert '_bplaneCurrentCorridorOk(targetBody, wantPe, -1, -1)' in finish
    assert '_bplaneHoldCorrection(' in finish
    cmd = (ROOT / 'cmd/munrecover.ks').read_text()
    assert cmd.index('COPYPATH(') < cmd.index('stateSet("mission_id"')
    assert 'missionOverrideClear()' in cmd and 'REMOVE NEXTNODE' in cmd
    assert 'bplane_budget_spent' not in cmd  # Recovery does not refund flown burns.
    assert 'stateRemovePrefix("burn_")' in cmd
    print('PASS: clean recovery activation, fuel ledger retained, and polar landing/return sequence')


def check_polar_contract():
    gate = body(ARRIVAL, 'bplaneCorrectionAllowed')
    condition = re.search(r'IF (ABS\(patch:PERIAPSIS - CAPTURE_PE\).*?) \{', gate, re.S)[1]
    for pe, inclination, reject in [(15000,0,True), (742000,90,True),
                                    (15000,90,False),(16000,89.9,False),(15000,89,True)]:
        assert evaluate(condition, patch=NS(PERIAPSIS=pe), CAPTURE_PE=15000,
                        BPLANE_PE_TOL=2000, planeErr=abs(inclination-90),
                        BPLANE_ANG_TOL=.2) == reject
    corridor = body(ARRIVAL, '_bplaneCorridorOk')
    waiver = re.search(r'IF (BPLANE_REQUIRE_PLANE.*?) \{', corridor)[1]
    for required, waived in [(0,True), (1,False)]:
        assert evaluate(waiver, BPLANE_REQUIRE_PLANE=required, err=None,
                        _bplanePlaneFeasible=lambda _: False) == waived
    safe = body(ARRIVAL, '_bplaneSafeEncounter')
    assert 'IF BPLANE_REQUIRE_PLANE <> 0 { RETURN FALSE. }' in safe
    planner = body(ARRIVAL, 'planBplaneCorrection')
    assert planner.index('required-plane-infeasible') < planner.index('SET planeMode TO "pe-only"')
    assert planner.index('required-plane-config-conflict') < planner.index('_bplanePlanPeOnly(')
    science = (ROOT / 'lib/science.ks').read_text()
    ops = body(science, 'phaseScienceOps')
    assert ops.index('yieldToPrompt()') < ops.index('nextPhase(')
    assert 'FOR site IN SCIENCE_SURVEY_POINTS' in ops
    assert 'GLOBAL SCIENCE_OPS_HOLD IS 0.' in science
    original = read_settings((ROOT / 'missions/RO8/mun_landing_return.ks').read_text(), {})
    for cfg in (PROFILE, original):
        assert cfg['BPLANE_REQUIRE_PLANE'] == 1
        assert cfg['TARGET_LAT'] == 44.593 and cfg['TARGET_LNG'] == -24.926
        assert cfg['SCIENCE_OPS_HOLD'] == 1
        assert cfg['SCIENCE_SURVEY_POINTS'] == [[-66.765,.528,10000],[-39.831,17.824,10000]]
    for key in original:
        if key.startswith(('RETURN_', 'SURFACE_RETURN_', 'LANDING_', 'TERRAIN_')):
            assert PROFILE[key] == original[key], key
    assert PROFILE['SHAPE_INC'] == 90 and PROFILE['SHAPE_AP'] == PROFILE['TARGET_AP']
    print('PASS: equatorial/high-Pe nodes rejected, no plane waiver, corrected sites and survey hold')


if __name__ == '__main__':
    check_solver()
    check_fuel_and_capture()
    check_resume_and_handoff()
    check_polar_contract()
