# Rendezvous and endpoint alignment

This is a staged flight test. Source fixtures pass; the replacement planner,
finite braking burn, attitude control and docking-part APIs still need native
validation. Start with a preview and a quicksave. The current two oppositely
orbiting surveyors are **not** the test pair; leave them mapping.

## Set up the vessels

- Use distinct names, for example `Chaser` and `Target`. Begin in safe orbits
  around the same body, preferably similar altitude and orbital plane **and
  direction**. Inclination alone does not describe the plane: LAN matters too.
- Finish/stop the survey and use its SCIENCE_OPS, SCANSAT_OPS or DONE prompt.
  Keep the chaser active, Abort clear, throttle zero, at1x, with no maneuver or
  interrupted burn. The commands preserve the selected mission and profile.
- Keep the target passive. Its kOS core can remain asleep during the distant
  intercept; both cores must be awake and unpacked for the close rehearsal.
  These commands do not change physics loading distances or core boot files.
  An awake core must also have the intended script running.
- For later capsule docking, tag the intended docking port `docking_port` on
  each vessel, or pass the same alternative tag to `docktest`. Existing part
  tags remain unchanged. With no such tag on a vessel, its control-reference
  forward axis and bounds envelope supply a bow endpoint. Duplicate tags or
  a tag on a non-port fail explicitly. Untagged ports are not guessed.

## Plan, burn, then match velocity

On the chaser, with an archive connection:

```kerboscript
RUNPATH("0:/cmd/rendezvous.ks", "preview", "Target").
```

This searches and records a comparison, then removes its own preview node.
It budgets departure **and** velocity matching, plus10m/s correction margin.
Defaults are500m/s total planned maneuver allowance and100m/s retained fuel;
the selected profile's excursion/RDV/MATCH reserve can only increase that
retained amount. For explicit alternative limits:

```kerboscript
RUNPATH("0:/cmd/rendezvous.ks", "preview", "Target", 800, 150).
```

The search uses bounded, zero-revolution Lambert arcs in three dimensions,
over departures spanning roughly two orbital periods. It tests up to eight
affordable candidates against native maneuver propagation. It aims500m
radially outside the target, not at its centre. Both predicted orbits must
retain10km surface/atmosphere clearance. A limited search can miss a feasible
transfer; failure is not proof of impossibility. The prediction is impulsive,
not a finite-burn collision certificate.

After inspecting the preview report, repeat with `plan`, inspect the node in
the map, and execute through the regular burn executor:

```kerboscript
RUNPATH("0:/cmd/rendezvous.ks", "plan", "Target").
RUNPATH("0:/cmd/exnode.ks").
```

After that burn completes, explicitly run:

```kerboscript
RUNPATH("0:/cmd/rendezvous.ks", "match", "Target").
```

If you already have a nearby, slowly moving target, start with `match` rather
than trying to manufacture another tiny intercept maneuver.

This may schedule a velocity-match burn **before** closest approach, using the
normal executor's KAC/solar/alignment/cutoff checks. It then uses bounded
relative-velocity pulses and resident1x coasts to reach a150m review stand-off
with relative speed below0.2m/s. Main-engine turns take time: no automatic
translation is attempted inside50m, no automatic staging is provided, and
poor alignment, motion of the target, a stage change, stale command, loss of
context, insufficient reserve or exhausted impulse allowance stops the test.
Native engine lag and turn capability remain unproven.

Failed/interrupted maneuver nodes and executor reports are preserved. A
failed non-node approach pulse records `rendezvous_active` and never resumes
on reboot. Only after reviewing it and manually restoring a separated
(>=150m), safe, velocity-matched idle orbit can you acknowledge that flag:

```kerboscript
RUNPATH("0:/cmd/rendezvous.ks", "reset", "Target").
```

This does not clear the normal executor's interrupted burn or delete a node.
Do not use reset to bypass an unfinished braking maneuver.

## Rehearse orientation on both cores

Once the pair is velocity-matched and within2km, activate the target and run:

```kerboscript
RUNPATH("0:/cmd/docktest.ks", "hold", "Chaser").
```

This holds its selected port/bow toward the chaser at zero throttle for at
most10minutes. It stays resident after you switch vessels, with a KAC expiry
alarm and a clock fallback. Both craft must remain at1x. It releases on loss
of the stand-off/motion/context limits. It does not survive a core reboot;
restart it explicitly after reviewing the scene.

Return to the chaser and run:

```kerboscript
RUNPATH("0:/cmd/docktest.ks", "check", "Target").
RUNPATH("0:/cmd/docktest.ks", "align", "Target").
```

`check` only reports. `align` turns at zero throttle and requires1second of
settled alignment, with both angular rates<=0.1deg/s, pointing/opposition
errors<=2deg and relative speed<=0.2m/s. It releases to SAS at the prompt;
target `hold` stays resident until its expiry. RCS is disabled during the
turn and its prior setting restored afterward. Neither command closes the
remaining gap. Sideways endpoint error is reported independently.

With real ports, `docked=True` requires reciprocal native PARTNER links.
For a bow fallback, even a zero bounds gap does **not** establish contact or
force transfer. Closing to contact, verifying coupled acceleration and a
separate operator-authorized pushing deorbit are future test stages; no such
burn is armed by these commands.

Reports go directly to `0:/logs/archive/_diagnostics/` as
`rendezvous_<craft>_<UT>.log` and `docktest_<craft>_<UT>.log`. Normal maneuver
execution remains in the craft's regular boot log. Capture the preview first,
then the match/attitude reports before trying closer operations.

Endpoint APIs: [kOS docking ports](https://ksp-kos.github.io/KOS/structures/vessels/dockingport.html)
and [bounds](https://ksp-kos.github.io/KOS/structures/vessels/bounds.html).
