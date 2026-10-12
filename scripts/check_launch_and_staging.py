"""Numerical/predicate regression checks; these do not run the kOS VM.

Evaluate source expressions against independent geometric and staged-burn
fixtures. Runtime staging, ascent guidance and compiled storage need KSP.
Run: python3 scripts/check_launch_and_staging.py
"""

import math
import re
from pathlib import Path
from types import SimpleNamespace

from check_burn_timing import Governor, TOLERANCE

ROOT = Path(__file__).resolve().parents[1]
WINDOW = (ROOT / 'lib/launch_window.ks').read_text()
BURN = (ROOT / 'lib/maneuver.ks').read_text()
TRANSFER = (ROOT / 'lib/maneuver_transfer.ks').read_text()


def body(source, name):
    start = source.index('FUNCTION ' + name + ' {')
    start = source.index('{', start) + 1
    depth = 1
    for match in re.finditer(r'"[^"\n]*"|//[^\n]*|[{}]', source[start:]):
        if match[0] == '{':
            depth += 1
        elif match[0] == '}':
            depth -= 1
            if depth == 0:
                return source[start:start + match.start()]
    raise AssertionError(name)


def evaluate(expression, **values):
    """Only the arithmetic/boolean expressions used by these fixtures."""
    expression = ' '.join(expression.split()).replace(':', '.')
    expression = expression.replace('<>', '!=')
    expression = re.sub(r'\bAND\b', 'and', expression)
    expression = re.sub(r'\bOR\b', 'or', expression)
    expression = re.sub(r'\bNOT\b', 'not', expression)
    expression = re.sub(r'(?<![<>!=])=(?!=)', '==', expression)
    helpers = dict(ABS=abs, MIN=min, MAX=max,
                   SIN=lambda x: math.sin(math.radians(x)),
                   COS=lambda x: math.cos(math.radians(x)),
                   TAN=lambda x: math.tan(math.radians(x)),
                   ARCSIN=lambda x: math.degrees(math.asin(x)),
                   ARCCOS=lambda x: math.degrees(math.acos(x)),
                   _windowNorm360=lambda x: x % 360)
    return eval(expression, {'__builtins__': {}, **helpers}, values)


def capture(pattern, source):
    return re.search(pattern, source, re.S)[1]


def launch_geometry():
    eta = body(WINDOW, 'launchPlaneEta')
    reachable = capture(r'RETURN (.*?)\.', body(WINDOW, 'launchPlaneReachable'))
    ratio_expr = capture(r'LOCAL ratio IS (.*?)\.', eta)
    longitude_expr = capture(r'LOCAL nodeAngle IS (.*?)\.\s*RETURN', eta)
    eta_expr = capture(r'RETURN (nodeAngle.*?)\.', eta)
    cases = 0
    for latitude in (-5.9, -0.1, 0, 3, 5.9):
        for inclination in (6, 45, 90, 120, 174):
            for lan in (0, 78, 359.99):
                for rotation in (0, 190, 359):
                    ship = SimpleNamespace(LATITUDE=latitude, LONGITUDE=-74.5,
                                           BODY=SimpleNamespace(ROTATIONANGLE=rotation,
                                                                ROTATIONPERIOD=21600))
                    assert evaluate(reachable, latitude_=latitude, inclination_=inclination)
                    ratio = evaluate(ratio_expr, SHIP=ship, targetInc=inclination)
                    rel = math.degrees(math.asin(max(-1, min(1, ratio))))
                    for ascending in (True, False):
                        rel_lng = rel if ascending else 180 - rel
                        node_angle = evaluate(longitude_expr, targetLan=lan, relLng=rel_lng, SHIP=ship)
                        seconds = evaluate(eta_expr, nodeAngle=node_angle, SHIP=ship)
                        assert 0 <= seconds < 21600
                        # Independent plane equation: the site at the
                        # predicted crossing must lie in the target plane.
                        longitude = math.radians(ship.LONGITUDE + rotation + seconds / 60)
                        lat = math.radians(latitude)
                        inc = math.radians(inclination)
                        ascending_longitude = math.radians(lan)
                        normal = (math.sin(inc) * math.sin(ascending_longitude),
                                  -math.sin(inc) * math.cos(ascending_longitude), math.cos(inc))
                        site = (math.cos(lat) * math.cos(longitude),
                                math.cos(lat) * math.sin(longitude), math.sin(lat))
                        assert abs(sum(a*b for a, b in zip(normal, site))) < 1e-10
                        cases += 1
    assert not evaluate(reachable, latitude_=10, inclination_=6)
    assert not evaluate(reachable, latitude_=10, inclination_=174)
    # Reboot delays must never shift the chosen crossing. Recalculate
    # after a miss, including a crossing just behind the current site.
    selector = body(WINDOW, 'launchPlaneWindow')
    wait_expr = capture(r'LOCAL waitTime IS (.*?)\.', selector)
    wait_guard = capture(r'UNTIL (.*?) \{', selector)
    for reboot_delay in (0, 90, 110, 121, 10921, 21605):
        for lead in (0, 10, 145):
            candidates = []
            for ascending, crossing in ((True, 120), (False, 10920)):
                elapsed = (crossing - reboot_delay) % 21600
                wait = evaluate(wait_expr, launchPlaneEta=lambda *args: elapsed,
                                ascendingNode=ascending, targetLan=78, targetInc=6, leadTime=lead)
                while not evaluate(wait_guard, waitTime=wait, minimumWait=15):
                    wait += 21600
                candidates.append(reboot_delay + wait)
            expected = min(crossing + orbit * 21600 - lead
                           for crossing in (120, 10920) for orbit in range(4)
                           if crossing + orbit * 21600 - lead >= reboot_delay + 15)
            assert min(candidates) == expected
    # True relative-plane angle: LAN is irrelevant for equatorial orbits.
    launch = (ROOT / 'lib/launch.ks').read_text()
    plane_expr = capture(r'LOCAL planeCos IS (.*?)\.\s*LOCAL planeErr', launch)
    for first, second, lan_error, expected in ((6, 6, 180, 12), (0, 0, 170, 0),
                                               (0, 6, 123, 6), (90, 90, 90, 90)):
        cosine = evaluate(plane_expr, SHIP=SimpleNamespace(ORBIT=SimpleNamespace(INCLINATION=first)),
                          tgtInc=second, lanErr=lan_error)
        assert abs(math.degrees(math.acos(max(-1, min(1, cosine)))) - expected) < 1e-6
    print(f'PASS: {cases} plane crossings, 18 delayed-window selections and relative-plane angles')


def engine(ignited, flameout, stage, decoupled=-1, thrust=20):
    return SimpleNamespace(IGNITION=ignited, FLAMEOUT=flameout, STAGE=stage,
                           DECOUPLEDIN=decoupled, AVAILABLETHRUST=thrust)


def staged_burn():
    active = capture(r'IF (.*?) \{', body(BURN, '_sma').split('FOR eng IN', 1)[1])
    recovery = body(BURN, '_burnRecoverThrust')
    eligible = capture(r'IF (.*?) \{', recovery.split('FOR eng IN', 1)[1])
    current = SimpleNamespace(NUMBER=4)
    def usable(eng):
        return evaluate(active, eng=eng)
    def next_engine(eng, limit=0):
        return evaluate(eligible, eng=eng, STAGE=current, BURN_STAGE_LIMIT=limit)
    assert usable(engine(True, False, 4))
    assert not usable(engine(True, True, 4))
    assert not usable(engine(False, True, 2))
    assert next_engine(engine(False, False, 3))       # combined separation/ignition
    assert next_engine(engine(False, False, 2))       # separate staging slots
    assert not next_engine(engine(False, False, 2, decoupled=3))
    assert not next_engine(engine(False, False, 5))   # already spent stage
    assert not next_engine(engine(False, False, 2), limit=3)
    assert not next_engine(engine(True, True, 4))     # dead active engine
    assert 'IF engineStage < 0 { RETURN FALSE. }' in recovery
    assert 'TIME:SECONDS >= deadline OR ABORT' in recovery
    assert 'IF events >= BURN_STAGE_MAX_EVENTS { RETURN FALSE. }' in recovery

    # Integrate a 950 m/s node: insertion stage contributes exactly 100,
    # then propulsion is unavailable through separation and ignition.
    # The SAME live governor and remaining node drive the upper stage.
    for latency in (0.5, 2, 6):
        for upper_acceleration in (2, 20, 100):
            governor = Governor()
            residual, spent, elapsed_gap = 950.0, 0.0, 0.0
            for _ in range(100000):
                acceleration = 10 if spent < 100 else upper_acceleration
                if spent >= 100 and elapsed_gap < latency:
                    assert governor.command(residual, 0, 0, 0.02) == 0
                    elapsed_gap += 0.02
                    assert not governor.stopped
                    continue
                output = governor.command(residual, 1, acceleration, 0.02)
                delivered = acceleration * output * 0.02
                if spent < 100:
                    delivered = min(delivered, 100 - spent)
                    spent += delivered
                residual -= delivered
                assert residual >= 0
                if governor.stopped:
                    break
            else:
                raise AssertionError('Staged burn failed to complete')
            assert spent == 100 and 0 <= residual <= TOLERANCE
    print('PASS: engine/stage eligibility and nine 100 + 850 m/s staged burns with ignition delays')


def integration():
    prelaunch = (ROOT / 'lib/prelaunch.ks').read_text()
    launch = (ROOT / 'lib/launch.ks').read_text()
    xfer = (ROOT / 'lib/xfer_plan.ks').read_text()
    # Deadlines survive reload; no blocking wait remains before band load.
    assert '_waitForPrelaunchUt' not in prelaunch
    assert 'launchWaitForLiftoff()' in launch
    gate = body(prelaunch, '_prelaunchWindowGate')
    immediate = gate.split('IF choice = "NOW" {', 1)[1].split('RETURN TRUE.', 1)[0]
    assert '_prelaunchClearPlanState().' in immediate
    assert 'SET LAUNCH_INCLINATION TO ABS(SHIP:LATITUDE).' in immediate
    window = body(WINDOW, 'launchWaitForLiftoff')
    assert 'launchPlaneWindow(plan["lan"], plan["inc"], plan["lead"], 15)' in window
    assert 'stateSet("phase", "PRELAUNCH")' in window
    assert 'SET plan TO LEXICON(' in window  # no in-place mutation of state cache
    # Aborted/partial departures must hold before either replan/delete path.
    transfer = body(xfer, 'phaseTransfer')
    assert transfer.count('_holdInterruptedTransfer()') == 3
    for removal in re.finditer(r'UNTIL NOT HASNODE \{ REMOVE NEXTNODE', transfer):
        preceding = transfer[:removal.start()]
        assert '_holdInterruptedTransfer()' in preceding
    execute = body(BURN, 'executeManeuver')
    assert execute.index('maneuverBurnInterrupted()') < execute.index('_mpb(')
    assert 'SET appliedDv TO 0' not in execute.split('_burnRecoverThrust(nd, burnTrace)', 1)[1]
    assert 'IF _ns()' not in execute
    # Search the full horizon; feasible candidates rank by departure cost.
    assert 'encounterCount >= 6' not in TRANSFER
    score = capture(r'SET score TO (-1e9.*?)\.', body(TRANSFER, '_localInterceptEval'))
    low = evaluate(score, nd=SimpleNamespace(DELTAV=SimpleNamespace(MAG=900)))
    high = evaluate(score, nd=SimpleNamespace(DELTAV=SimpleNamespace(MAG=1100)))
    assert low < high
    print('PASS: window persistence, immediate-east choice, interrupted-transfer guards and cost ranking')


if __name__ == '__main__':
    launch_geometry()
    staged_burn()
    integration()
