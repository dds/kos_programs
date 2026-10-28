"""Numerical regression checks for node-burn scheduling (no KSP required).

Evaluate the throttle-limit expressions from maneuver.ks in a discrete
physics model. The main loop can stall independently of the live lock.
This exercises command latency and latching, not the kOS VM or game engine.
Run: python3 scripts/check_burn_timing.py
"""

import math
import re
from pathlib import Path
from types import SimpleNamespace as NS


SOURCE = (Path(__file__).resolve().parents[1] / "lib/maneuver.ks").read_text()
GOVERNOR = SOURCE.split("LOCAL FUNCTION _burnNodeThrottle {", 1)[1].split(
    "LOCAL FUNCTION _burnImpulseThrottle", 1)[0]
TOLERANCE = float(
    re.search(r"GLOBAL BURN_TRIM_ABS_COMPLETE_DV IS ([0-9.]+)\.", SOURCE)[1]
)


def expression(pattern):
    text = " ".join(re.search(pattern, GOVERNOR, re.S)[1].split())
    return compile(text, "<maneuver.ks throttle expression>", "eval")


HORIZON = expression(r"LOCAL horizon IS (.*?)\.\s")
OUTPUT = expression(r'SET cutoff\["output"\] TO (MIN\(.*?)\.\s')
PROJECTED_REMAINING = expression(r'SET rem TO (MIN\(rem, MAX\(0, forwardRem\)\))\.\s')
REBOUND_EPS = float(re.search(r'GLOBAL BURN_NODE_REBOUND_EPS IS ([0-9.]+)\.', SOURCE)[1])
AXIS_GUARD = float(re.search(r'GLOBAL BURN_NODE_FLIP_REMAINING_DV IS ([0-9.]+)\.', SOURCE)[1])
MAIN_HORIZON = compile(re.search(r'LOCAL horizon IS (.*?)\.\s',
    SOURCE.split('ELSE IF rem > BURN_TRIM_ABS_COMPLETE_DV {', 1)[1])[1],
    '<main-loop horizon>', 'eval')
MAIN_THROTTLE = compile(re.search(r'LOCAL nextThrottle IS (.*?)\.\s', SOURCE)[1],
    '<main-loop throttle>', 'eval')


def check_duration_limits():
    import check_landing_guidance as ks
    from check_burn_watchdog import fixture as governor_fixture
    # Execute the real helper, including engines with existing partial/zero
    # limits. Acceleration is the configured value, not unlimited engine power.
    for dv in (.008, .1589, 1, 9.7422, 49, 55.8777, 900):
        for acc in (.01, .32, 3.2, 46, 400):
            env, _, _, _ = governor_fixture(acc=acc)
            engines = [NS(THRUSTLIMIT=x) for x in (100, 50, 0)]
            env['SHIP'].ENGINES = engines
            scale = ks.call('_burnLimitThrust', env, dv)
            assert 0 < scale <= 1
            assert abs(scale - min(1, dv / (acc * 2))) < 1e-12
            assert [e.THRUSTLIMIT for e in engines] == [100*scale, 50*scale, 0]
            assert dv / (acc * scale) >= 2 - 1e-12
            if dv / acc >= 2:
                assert scale == 1
    for acc in (0, -1, math.nan, math.inf):
        env, _, _, _ = governor_fixture(acc=acc)
        engine = NS(THRUSTLIMIT=37)
        env['SHIP'].ENGINES = [engine]
        assert ks.call('_burnLimitThrust', env, 9.7422) == 1
        assert engine.THRUSTLIMIT == 37
    print('PASS: actual duration limiter adapts to acceleration, preserves relative/zero engine limits and leaves slow burns at available power')


def check_full_power_cutoff():
    import check_landing_guidance as ks
    from check_burn_watchdog import fixture as governor_fixture
    # Main-loop expression plus actual live governor with one physics tick of
    # control latency. Test low acceleration AND high acceleration, tiny burns,
    # precision tails, a delayed loop and a genuine heartbeat timeout.
    builtins = {'__builtins__': {}, 'MAX': max, 'MIN': min}
    cases = 0
    for dv in (.008, .1589, 9.7422, 55.8777):
        for configured_acc in (.32, 3.2, 400):
            acc = configured_acc * min(1, dv/(configured_acc*2))
            for tick in (.02, .1, .25):
                for stall in (0, .4, 1.2):
                    cases += 1
                    env, cutoff, node, live = governor_fixture(acc=acc, cap=dv*1.01+.05)
                    env['BURN_TRIM_ABS_COMPLETE_DV'] = .001
                    residual, output, delivered, command = dv, 0, 0, 0
                    last_main = -tick
                    max_command = 0
                    for i in range(10000):
                        now = i*tick
                        residual -= delivered*acc*tick
                        assert residual >= -1e-10, (dv, acc, tick, stall, residual)
                        env['TIME'].SECONDS = now
                        env['SHIP'].THRUST = delivered*acc
                        node.DELTAV = ks.Vec((max(0, residual), 0, 0))
                        if not (tick <= now < tick+stall):
                            dt = now-last_main
                            horizon = eval(MAIN_HORIZON, builtins, dict(dt=dt))
                            command = eval(MAIN_THROTTLE, builtins,
                                           dict(rem=max(0, residual), ma=acc, horizon=horizon))
                            max_command = max(max_command, command)
                            cutoff['heartbeat'] = now
                            last_main = now
                        delivered, output = output, live(command)
                        if cutoff['reason'] and delivered == 0 and output == 0:
                            break
                    else:
                        raise AssertionError(('No cutoff', dv, acc, tick, stall))
                    if stall > 1:
                        assert cutoff['reason'] == 'live-command-stale'
                    else:
                        assert cutoff['reason'] == 'live-node-trim', cutoff
                        assert residual <= .001
                    assert max_command == 1  # no blanket half-throttle ceiling
                    assert live(1) == 0  # later residual changes cannot reignite
    # Native report: previously 10% engine limit AND half throttle at 9.742m/s.
    # At configured3.2m/s^2 this is a3.04s full-power impulse, not60.9s.
    assert 9.7422/(3.2*.1*.5) > 60
    assert 9.7422/3.2 < 3.1
    executor = SOURCE.split('GLOBAL FUNCTION executeManeuver {', 1)[1]
    assert executor.index('_burnLimitThrust(bdv)') < executor.index('_cst(nd)')
    assert 'MIN(0.5, nextThrottle)' not in executor
    print(f'PASS: {cases} actual-governor burns retain precision cutoff, latency margin and stale-command latch at full power; reported double limit reproduced')


class Governor:
    """Model the lock's signed residual and persistent cutoff state."""

    def __init__(self):
        self.stopped = False
        self.best_rem = -1
        self.reason = ''

    def command(self, residual, ceiling, acceleration, tick, forward_residual=None):
        if self.stopped:
            return 0.0
        if ceiling <= 0:
            self.best_rem = -1
            return 0.0
        if acceleration <= 0:
            self.best_rem = -1
            return 0.0
        if not math.isfinite(residual) or abs(residual) <= TOLERANCE or residual < 0:
            self.stopped = True
            return 0.0
        if forward_residual is None:
            forward_residual = residual
        if abs(residual) <= AXIS_GUARD and forward_residual <= TOLERANCE:
            self.stopped, self.reason = True, 'live-thrust-axis-trim'
            return 0.0
        if self.best_rem >= 0 and abs(residual) > self.best_rem + REBOUND_EPS:
            self.stopped, self.reason = True, 'live-residual-rebound'
            return 0.0
        self.best_rem = abs(residual) if self.best_rem < 0 else min(self.best_rem, abs(residual))
        values = dict(rem=abs(residual), command=ceiling, independentLimit=ceiling,
                      acc=acceleration, tickDt=tick)
        builtins = {"__builtins__": {}, "MAX": max, "MIN": min}
        if abs(residual) <= AXIS_GUARD:
            values['rem'] = eval(PROJECTED_REMAINING, builtins,
                                 dict(rem=abs(residual), forwardRem=forward_residual))
        values["horizon"] = eval(HORIZON, builtins, values)
        return eval(OUTPUT, builtins, values)


def fly_tail(acceleration, tick, main_stall, latency_ticks=0):
    residual = 0.5
    # Previous main-loop sample was 1.5 m/s; it cannot refresh its
    # command during the simulated logging/CPU stall.
    ceiling = min(0.5, 1.5 / acceleration)
    governor = Governor()
    initial = governor.command(residual, ceiling, acceleration, tick)
    pending = [initial] * latency_ticks
    elapsed = 0.0
    minimum = residual
    for _ in range(10000):
        if elapsed >= main_stall:
            ceiling = min(0.5, abs(residual) / acceleration)
        output = governor.command(residual, ceiling, acceleration, tick)
        pending.append(output)
        delivered = pending.pop(0)
        residual -= delivered * acceleration * tick
        elapsed += tick
        minimum = min(minimum, residual)
        if governor.stopped and not any(pending):
            break
    else:
        raise AssertionError("Tail failed to reach cutoff")
    assert minimum >= 0, (acceleration, tick, main_stall, latency_ticks, minimum)
    assert residual <= TOLERANCE, residual
    # A residual that grows later must never reignite an already-cut burn.
    assert governor.command(2.0, 1.0, acceleration, tick) == 0


def main():
    check_duration_limits()
    check_full_power_cutoff()
    # Reproduce the reported scale without inventing a failed taper law:
    # a perfectly reasonable previous command, held for one extra second,
    # turns +0.5 m/s remaining into -1.0 m/s remaining.
    old_residual = 0.5 - 20 * 0.075 * 1.0
    assert old_residual == -1.0

    cases = 0
    for acceleration in (0.05, 0.2, 1, 20, 200):
        for tick in (0.02, 0.1, 0.25):
            for stall in (0, 0.1, 1, 5):
                for latency in (0, 1):
                    fly_tail(acceleration, tick, stall, latency)
                    cases += 1

    # Sign reversal at a small magnitude must cut and latch immediately.
    governor = Governor()
    assert governor.command(-0.1, 0.5, 20, 0.02) == 0
    assert governor.command(1, 0.5, 20, 0.02) == 0
    # Invalid telemetry must stop the burn and keep it stopped.
    for residual in (math.nan, math.inf, -math.inf):
        governor = Governor()
        assert governor.command(residual, 0.5, 20, 0.02) == 0
        assert governor.command(1, 0.5, 20, 0.02) == 0
    # Pausing or a stage without thrust must not latch completion.
    governor = Governor()
    assert governor.command(5, 0, 20, 0.02) == 0
    assert not governor.stopped
    assert governor.command(5, 1, 0, 0.02) == 0
    assert not governor.stopped
    assert governor.command(5, 1, 20, 0.02) > 0

    # Low-thrust finite burns can retain transverse node error. A vector
    # magnitude of several m/s must not carry thrust past the useful axis.
    for acceleration in (0.05, 0.2, 2):
        for tick in (0.02, 0.1, 0.25):
            governor = Governor()
            forward, lateral = 3.0, 4.0
            pending = [0.0]
            for _ in range(100000):
                output = governor.command(math.hypot(forward, lateral), 1,
                                          acceleration, tick, forward)
                pending.append(output)
                forward -= pending.pop(0) * acceleration * tick
                assert forward >= 0
                if governor.stopped and not any(pending):
                    break
            else:
                raise AssertionError('Transverse-error tail did not stop')
            assert governor.reason == 'live-thrust-axis-trim'
            assert math.hypot(forward, lateral) > TOLERANCE
    # Rebound is measured against the best powered residual, not merely
    # the previous sample; it must latch even during a stalled main loop.
    governor = Governor()
    for residual in (30, 15, 8, 8.2, 8.4):
        assert governor.command(residual, 1, 0.2, 0.02) > 0
    assert governor.command(8.6, 1, 0.2, 0.02) == 0
    assert governor.reason == 'live-residual-rebound'
    assert governor.command(2, 1, 0.2, 0.02) == 0
    # A staging/coast gap resets this baseline: orbital motion while
    # propulsion is stopped must not be mistaken for a powered rebound.
    for stopped_throttle, stopped_acceleration in ((0, 0.2), (1, 0)):
        governor = Governor()
        assert governor.command(8, 1, 0.2, 0.02) > 0
        assert governor.command(8, stopped_throttle, stopped_acceleration, 0.02) == 0
        assert governor.command(9, 1, 0.2, 0.02) > 0
    governor = Governor()
    assert governor.command(8, 1, 0.2, 0.02) > 0
    assert governor.command(9, 1, 0, 0.02) == 0
    assert not governor.stopped  # starvation wins over apparent rebound

    # Check the integration points that make the scheduler model apply.
    code = re.sub(r"//[^\n]*", "", GOVERNOR)
    assert not re.search(r"\b(WAIT|PRINT|LOG|mLog\w*|stateSet)\b", code)
    assert "LOCK THROTTLE TO _burnNodeThrottle(" in SOURCE
    assert 'cutoff["reason"] <> ""' in GOVERNOR
    assert "VDOT(ignitionVec, residual) < 0" in GOVERNOR
    assert 'VDOT(SHIP:FACING:FOREVECTOR, residual)' in GOVERNOR
    assert 'rem > cutoff["bestRem"] + BURN_NODE_REBOUND_EPS' in GOVERNOR
    assert GOVERNOR.index('IF acc <= 0') < GOVERNOR.index('rem > cutoff["bestRem"]')
    assert 'mLogWarn("BURN tick status="' not in SOURCE
    flush = SOURCE.index("FOR traceLine IN burnTrace")
    shutdown = SOURCE.rindex("LOCK THROTTLE TO 0.0.", 0, flush)
    assert "_burnVerifyCutoff()" in SOURCE[shutdown:flush]
    verify = (Path(__file__).resolve().parents[1] / 'lib/thrust_cutoff.ks').read_text()
    assert "WAIT 0.02." in verify and "eng:SHUTDOWN." in verify
    assert 'UNLOCK STEERING.' in SOURCE[shutdown:flush]
    assert 'UNLOCK THROTTLE.' in SOURCE[shutdown:flush]
    assert 'LOCK STEERING TO BURN_ABORT_HOLD_VECTOR' not in SOURCE
    print(f"PASS: reproduced old -1 m/s overshoot; {cases} delayed-loop tails stayed positive")
    print("PASS: cutoff latch, reversal, invalid telemetry, pause/resume, no-thrust, and lock/logging integration")
    print("PASS: nine low-thrust vector tails, powered rebound cutoff, staging baseline reset and control release")


if __name__ == "__main__":
    main()
