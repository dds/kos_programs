"""Numerical regression checks for node-burn scheduling (no KSP required).

Evaluate the throttle-limit expressions from maneuver.ks in a discrete
physics model. The main loop can stall independently of the live lock.
This exercises command latency and latching, not the kOS VM or game engine.
Run: python3 scripts/check_burn_timing.py
"""

import math
import re
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "lib/maneuver.ks").read_text()
GOVERNOR = SOURCE.split("LOCAL FUNCTION _burnNodeThrottle {", 1)[1].split(
    "LOCAL FUNCTION _burnTraceAdd", 1
)[0]
TOLERANCE = float(
    re.search(r"GLOBAL BURN_TRIM_ABS_COMPLETE_DV IS ([0-9.]+)\.", SOURCE)[1]
)


def expression(pattern):
    text = " ".join(re.search(pattern, GOVERNOR, re.S)[1].split())
    return compile(text, "<maneuver.ks throttle expression>", "eval")


HORIZON = expression(r"LOCAL horizon IS (.*?)\.\s")
OUTPUT = expression(r'SET cutoff\["output"\] TO (MIN\(.*?)\.\s')


class Governor:
    """Model the lock's signed residual and persistent cutoff state."""

    def __init__(self):
        self.stopped = False

    def command(self, residual, ceiling, acceleration, tick):
        if ceiling <= 0 or self.stopped:
            return 0.0
        if not math.isfinite(residual) or abs(residual) <= TOLERANCE or residual < 0:
            self.stopped = True
            return 0.0
        if acceleration <= 0:
            return 0.0
        values = dict(rem=abs(residual), command=ceiling, acc=acceleration, tickDt=tick)
        builtins = {"__builtins__": {}, "MAX": max, "MIN": min}
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
    # Reproduce the reported scale without inventing a failed taper law:
    # a perfectly reasonable previous command, held for one extra second,
    # turns +0.5 m/s remaining into -1.0 m/s remaining.
    old_residual = 0.5 - 20 * 0.075 * 1.0
    assert old_residual == -1.0

    cases = 0
    for acceleration in (1, 20, 200):
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

    # Check the integration points that make the scheduler model apply.
    code = re.sub(r"//[^\n]*", "", GOVERNOR)
    assert not re.search(r"\b(WAIT|PRINT|LOG|mLog\w*|stateSet)\b", code)
    assert "LOCK THROTTLE TO _burnNodeThrottle(" in SOURCE
    assert 'cutoff["reason"] <> ""' in GOVERNOR
    assert "VDOT(ignitionVec, residual) < 0" in GOVERNOR
    assert 'mLogWarn("BURN tick status="' not in SOURCE
    flush = SOURCE.index("FOR traceLine IN burnTrace")
    shutdown = SOURCE.rindex("LOCK THROTTLE TO 0.0.", 0, flush)
    assert "WAIT 0.01." in SOURCE[shutdown:flush]
    print(f"PASS: reproduced old -1 m/s overshoot; {cases} delayed-loop tails stayed positive")
    print("PASS: cutoff latch, reversal, invalid telemetry, pause/resume, no-thrust, and lock/logging integration")


if __name__ == "__main__":
    main()
