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
    source = body(ARRIVAL, '_bplanePlanPeOnly')
    assignments = {name: expr.replace('^', '**') for name, expr in
                   re.findall(r'LOCAL (grad2|stepPro|stepRad|stepSize|scale) IS (.*?)\.\n', source)}
    fractions = re.search(r'FOR fraction IN LIST\((.*?)\)', source)[1]
    fractions = [float(value) for value in fractions.split(',')]
    iterations = int(re.search(r'UNTIL iteration >= (\d+)', source)[1])
    fd = float(re.search(r'LOCAL FD_STEP\s+IS (\d+\.\d+)', ARRIVAL)[1])

    def solve(patch, cap):
        pro, radial = 0., 0.
        for _ in range(iterations):
            pe = patch(pro, radial)
            if pe is None:
                return None
            if abs(pe - 15000) <= PROFILE['BPLANE_PE_TOL']:
                return pro, radial, pe
            gradients = []
            for axis in range(2):
                slope = 0.
                for probe in (fd, -fd):
                    sample = patch(pro + (probe if axis == 0 else 0),
                                   radial + (probe if axis == 1 else 0))
                    if sample is not None:
                        slope = (sample - pe) / probe
                        break
                gradients.append(slope)
            env = dict(gradients=gradients, peError=15000-pe,
                       dvCap=cap, SQRT=math.sqrt)
            env['grad2'] = evaluate(assignments['grad2'], **env)
            if env['grad2'] < .000001:
                return None
            for name in ('stepPro', 'stepRad', 'stepSize', 'scale'):
                env[name] = evaluate(assignments[name], **env)
            for fraction in fractions:
                trial_pro = pro + env['stepPro'] * env['scale'] * fraction
                trial_rad = radial + env['stepRad'] * env['scale'] * fraction
                trial_pe = patch(trial_pro, trial_rad)
                if math.hypot(trial_pro, trial_rad) <= cap + .001 and trial_pe is not None:
                    if abs(trial_pe - 15000) < abs(pe - 15000):
                        pro, radial = trial_pro, trial_rad
                        break
            else:
                return None
        return None

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
        result = solve(patch, PROFILE['BPLANE_DV_CAP'])
        assert result is not None
        pro, radial, pe = result
        assert abs(pe - 15000) <= 2000
        assert math.hypot(pro, radial) < 50
        assert solve(patch, .5) is None  # Cannot buy the required correction.
        fixtures += 1
    assert solve(lambda *_: None, 50) is None
    assert solve(lambda *_: 742000, 50) is None  # No control authority.
    assert solve(lambda *_: 15000, 50) == (0., 0., 15000)
    assert 'LIST("PROGRADE", "RADIALOUT")' in source
    assert 'SET nd:NORMAL' not in source
    print(f'PASS: {fixtures} nonlinear Pe solves, lost trial patches, exhausted budgets and zero authority')


def check_fuel_and_capture():
    gate = body(ARRIVAL, '_bplaneCorrectionAllowed')
    needed = re.search(r'LOCAL needed IS (.*?)\.', gate, re.S)[1]
    for correction, capture, fuel, allowed in [
        (25, 300, 899, True), (50, 799, 899, True),
        (50, 800, 899, False), (10, 300, 0, False)]:
        env = dict(nd=NS(DELTAV=NS(MAG=correction)), targetBody=None,
                   planned={'patch': object()}, _bplaneCaptureCost=lambda *_: capture,
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
                                   'COAST_2HALF', 'CAPTURE', 'SCIENCE_OPS', 'DONE']
    assert PROFILE['CAPTURE_DIR'] == '' and PROFILE['CAPTURE_INC'] == -1
    assert PROFILE['BPLANE_TRIM_RESERVE_DV'] == -1
    assert PROFILE['BPLANE_MAX_ARRIVAL_SHIFT'] == -1
    assert PROFILE['BPLANE_MAX_CAPTURE_DV_INCREASE'] == -1
    assert PROFILE['BPLANE_TRIM_TOTAL_DV_CAP'] == 60
    assert 'GLOBAL BPLANE_PE_ONLY IS 0.' in ARRIVAL
    planner = body(ARRIVAL, 'planBplaneCorrection')
    assert planner.index('_bplanePlanPeOnly(') < planner.index('measureArrival(')
    resume = body(ARRIVAL, '_bplaneExistingNodeAcceptable')
    assert resume.index('IF BPLANE_PE_ONLY <> 0') < resume.index('_bplaneCorrectionAllowed(')
    for name in ('phaseBplane', 'phaseRefineBplane'):
        phase = body(ARRIVAL, name)
        assert phase.index('_bplaneClearCoastTimes()') < phase.index('executeManeuver()')
        assert phase.index('_bplaneFinishPeRecovery(') < phase.index('_bplaneSafeEncounter(')
    finish = body(ARRIVAL, '_bplaneFinishPeRecovery')
    assert '_bplaneCurrentCorridorOk(targetBody, wantPe, -1, -1)' in finish
    assert '_bplaneHoldCorrection(' in finish
    cmd = (ROOT / 'cmd/munrecover.ks').read_text()
    assert cmd.index('COPYPATH(') < cmd.index('stateSet("mission_id"')
    assert 'missionOverrideClear()' in cmd and 'REMOVE NEXTNODE' in cmd
    assert 'bplane_budget_spent' not in cmd  # Recovery does not refund flown burns.
    assert 'stateRemovePrefix("burn_")' in cmd
    print('PASS: clean recovery activation, stale node/timing cleanup, strict handoff and capture-only sequence')


if __name__ == '__main__':
    check_solver()
    check_fuel_and_capture()
    check_resume_and_handoff()
