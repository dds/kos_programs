# Check performance

Measured locally on 2026-10-17 against archived commit `03b52a4`. Timings
vary with CPU load. These are Python fixture times, not flight CPU timings
or proof of kOS compilation/game behavior.

The original 27-file pass took **147.0 seconds**. After optimization, the
28-file full pass, including new harness/CPU recovery regressions, took
**11.8 seconds**. The routine pass took **9.5 seconds** for 124 individual
calls, excluding only the full powered-ascent numerical comparison. Each
routine call measured below one second (maximum 0.80 s; 0.83 s in the full
pass). A file can contain several checks and exceed
one second in total.

| File | Before | Full pass after |
|---|---:|---:|
| `check_landing_economy.py` | 44.60 s | 1.57 s |
| `check_landing_braking.py` | 27.81 s | 1.10 s |
| `check_direct_return.py` | 26.60 s | 2.28 s |
| `check_landing_light.py` | 24.14 s | 1.55 s |
| `check_landing_alignment.py` | 6.29 s | 0.32 s |

| Individual check call | Before | After | Frequency |
|---|---:|---:|---|
| Full finite-burn predictor / independent Heun ascent | 24.25 s | 1.82 s | Requested slow pass |
| Each main braking simulation (`g=...`) | 3.35–10.24 s | 0.09–0.33 s | Routine |
| Economy efficiency and staged/curved matrix | 39.04 s together | 0.61 / 0.58 s | Routine, two scenario groups |
| Afternoon light geometry | 6.48 s | 0.33 s | Routine |
| Finite attitude slew | 5.30 s | 0.14 s | Routine |
| Independent conic propagation | 1.65 s | 0.26 s | Routine |

Use these commands:

```sh
make check        # routine pass; also used by make pre-commit
make check-slow   # only the full predictor/Heun comparison
make check-all    # routine and slow together
make check-times # full pass with slowest files and individual calls
python3 -B scripts/run_checks.py --suite fast --timings --json /tmp/kos-fast.json
python3 -B scripts/run_checks.py --suite all --timings --json /tmp/kos-all.json
python3 -B scripts/check_direct_return.py --slow  # focused full direct-return checks
```

The runner executes each script's existing main block in a separate process.
It discovers and times directly called check functions, including every
iteration of parameterized simulations, and propagates failures. JSON includes
every individual call, whole-file wall time and exit status. The one-second
target is a local measurement, not a timing assertion that flakes on busy
machines. Reprofile after changes; optimize or explicitly move genuinely
expensive comparisons to the requested pass. Slow checks are never removed.

Run the full pass when modifying the direct-return predictor, numerical
oracles or shared fixture executor. Routine direct-return checks still cover
measured context, independent conic propagation, limits and preview orchestration.

Most original cost was repeated regex translation, expression compilation,
statement dispatch and assignment compilation on every simulated tick. The
fixture subset now compiles once to Python and caches code, retaining live
environment values. Source/tree changes invalidate the corresponding caches;
function-local copies, callbacks, return/break behavior, default parameters
and convergence guards remain covered. Small 3D vector operations avoid
NumPy's general axis/broadcast dispatch.

Independent RK4 coast and Heun ascent oracles now use scalar components
instead of allocating tiny NumPy arrays per integration substep. The original
one-second RK4 and 0.01-second Heun steps, production predictor steps, input
matrices, assertions and acceptance tolerances remain. A comparison against
the archived original oracles changed Heun periapsis by less than 2e-9 m,
RK4 position by less than 2e-9 m and velocity by less than 2e-13 m/s on the
existing eccentricity matrix. These optimizations do not establish new flight
accuracy or broaden the model's supported physics.
