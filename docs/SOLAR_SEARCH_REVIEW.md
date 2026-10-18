# Solar search: RO9 evidence and refinement

The supplied `solardiag_RO9_1644877384.log` records a successful search in
63.78 seconds, ending at flow 0.3813675. It has no alignment timeout, dropped
rows, engine thrust or active warp. This attempt does not reproduce the
earlier reported steering stall.

Settled readings, with times relative to the diagnostic header:

| Measurement | Time (s) | Flow | Pointing error |
|---|---:|---:|---:|
| Unbenchmarked cache | 7.28 | 0 | 5.98° |
| fixed-1 | 10.38 | 0.001086 | 0.18° |
| fixed-2 | 20.96 | 0 | 3.52° |
| fixed-3 | 31.10 | 0.023659 | 3.62° |
| fixed-4 | 43.88 | 0 | 2.20° |
| fixed-5 | 50.72 | 0.381340 | 3.69° |
| fixed-6 | 57.12 | 0 | 3.91° |
| Best hold | 63.74 | 0.381366 | 3.63° |

The winning body-frame Sun direction was `(0, 0.866, 0.5)`, between the
craft's +Y and +Z axes. In the scanned panel part's frame it was -Y. The
craft had one reported `solarPanels5` panel module and one `sasModule`
reaction wheel. The requested and steering-manager attitudes agreed after
the initial transition. IPU was 2000 during the search and no autopilot
suppression was recorded. Battery charge fell from 39.45% to 38.25%, reaching
a minimum of 37.68% before the winning orientation began recovering charge.

The sample intervals account for the delay through actual turns, damping
and the 1.5-second readout waits. The initial cache had no valid saved peak
and duplicated fixed-1. Skipping that cache validation removes redundant
measurement work; the initial turn to that axis is still necessary.

Six axes reveal the strongest coarse direction but cannot prove an optimum
between axes. A new optional refinement tightens the winner's pointing to
1°, measures four +/-15° tilts, and uses their two flow gradients to propose
a combined direction. Only a measured gain above 0.2% can replace the winner.
The calculation works for illuminated panel groups with cosine response;
shadows, tracking panels or nonlinear responses can invalidate its estimate,
so the estimate itself never authorizes a cache update.

Refinement has a 45-second shared budget and 15 seconds per turn, while
reserving time to return to the best measured direction. Incomplete refinement
keeps its best measured result, including the original coarse winner. Abort
or a failed final return cannot publish a new cache. Setting
`SOLAR_REFINE_TIMEOUT` to 0 disables the optional pass. A proven older axis
is refined directly; subsequent calls validate the learned direction without
repeating discovery. See the README for settings and commands.

The new pass has source-driven finite-turn tests for tilted and diagonal
mounts, plus tests for multiple panels, failed peak predictions, measurement
noise, timeouts, cache upgrades and recorder eviction. It has not flown in
KSP yet. The supplied flight already points near its best coarse axis;
substantial additional flow on this particular craft is not established.

Diagnostic schema 2 preserves up to 24 settled measurements independently
of the detailed turn ring. Each includes the requested axis, actual Sun axis
in craft coordinates, flow, pointing error and timestamp. These let the next
flight compare coarse and refined flow and distinguish pointing error from
panel response. `rawCommand` is the raw `SHIP:CONTROL` channel, not actual
wheel torque; zero raw values did not mean the craft failed to turn in this
flight. Module `ALLFIELDS` reports field names/types, not their current values.
Automatic quiet export and existing archive/offline guards remain in place.
