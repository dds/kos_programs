# Proposal: Launch Plane Selection + Departure Shaping

## Problem

Our Minmus transfers are too fragile when we launch into equatorial LKO and ask
the transfer planner to find the tilted Minmus encounter from there. Minmus is
only modestly inclined, but from low Kerbin orbit that still creates a real
plane mismatch at the worst possible time: the departure burn has to solve
phase, energy, and plane at once.

We already have two useful pieces:

- `lib/prelaunch.ks` can wait until KSC rotates into a target plane, then pass a
  matching `LAUNCH_INCLINATION` to MechJeb. This is currently used for
  launch-to-rendezvous and fixed `CAPTURE_LAN` missions.
- `lib/orbit_shape.ks` can match `INC+LAN` after parking with the closed-form
  `planPlaneMatch` burn, then continue with apsis/AoP shaping.

The proposal is to make both paths first-class and composable.

## Recommendation

Do both, but do them in separate layers:

1. **Launch-plane targeting** for known planes before liftoff.
2. **Departure shaping** after parking when the best plane is computed later or
   when direct launch is unavailable.

For Minmus, the default should be launch-plane targeting: wait for KSC to pass
through Minmus' Kerbin orbital plane, launch at Minmus' inclination, then let
`XING/BPLANE/COAST/CAPTURE/SHAPE` do less work.

For comets, asteroids, Jool tours, and later dynamic routes, the default should
be allowed to park first, then use `DEPARTURE_SHAPE` to enter a computed
departure plane before `XING` or `ESCAPE`.

## Why This Split

### Direct launch is cheaper when the target plane is known

Launching directly into Minmus' plane should save the LKO plane-change cost and
reduce the local-transfer search burden. This also reuses the most flight-like
code we already have: `PRELAUNCH` rendezvous timing already understands
"surface site rotates into target orbital plane".

### Orbit shaping is more general

For grand tours, the useful parking plane may not be "the destination body's
current orbital plane". It might be:

- the Lambert departure plane for a specific transfer window,
- an asteroid/comet target's current orbit plane,
- a staging orbit chosen for a later gravity assist,
- or simply "whatever plane the next hop planner discovered".

That argues for keeping `SHAPE` as the universal in-space correction mechanism.
It also lets us recover when the launch site cannot reach the requested plane,
the window is too far away, or MechJeb ascent misses the plane by more than we
like.

## Proposed Interface

Add a small launch/departure intent vocabulary in mission config:

```ini
# Before launch:
LAUNCH_PLANE_MODE = BODY_ORBIT       # NONE | BODY_ORBIT | VESSEL_ORBIT | CFG | AUTO
LAUNCH_PLANE_TARGET = MINMUS         # body or vessel name; optional
LAUNCH_PLANE_LEAD = 145              # seconds before exact plane crossing

# After parking:
DEPARTURE_SHAPE_MODE = OFF           # OFF | TARGET_ORBIT | COMPUTED | AUTO
DEPARTURE_SHAPE_BEFORE = XING        # usually XING or ESCAPE
DEPARTURE_SHAPE_MAX_DV = 350         # optional guardrail
```

Minimal first version can be smaller:

- `LAUNCH_PLANE_MODE = BODY_ORBIT`
- `LAUNCH_PLANE_TARGET = MINMUS`
- optional `DEPARTURE_SHAPE_MODE = TARGET_ORBIT`

`LAUNCH_PLANE_TARGET` should default rather than fail silently. Resolution
order:

1. explicit `LAUNCH_PLANE_TARGET`,
2. mission `TARGET`,
3. active KSP target, when it is a body or vessel compatible with the selected
   mode.

`AUTO` should not mean "give up and fix the plane in LKO after a short wait".
Low-orbit plane changes are too expensive: a roughly 6 degree plane change in a
100 km Kerbin orbit costs about 240 m/s. For a reachable launch plane, waiting
on the pad is the right answer.

For a plane to be reachable from the pad, the launch-site latitude magnitude
must be less than or equal to the plane's maximum latitude:

```text
abs(site latitude) <= min(inclination, 180 - inclination)
```

At KSC, this means Minmus' roughly 6 degree plane is reachable, so `AUTO`
waits for the node and launches directly. If a requested plane is not reachable
from the launch site, `AUTO` may launch into the best available parking plane
and leave the plane correction to a later mid-course correction or explicit
mission phase. It should log that fallback loudly.

## Proposed Behavior

### 1. PRELAUNCH resolves the requested launch plane

Extend `phasePrelaunch` to resolve a plane from:

- existing rendezvous target vessel,
- explicit `CAPTURE_INC/CAPTURE_LAN`,
- `LAUNCH_PLANE_MODE = BODY_ORBIT` using `TARGET` or `LAUNCH_PLANE_TARGET`,
- `LAUNCH_PLANE_MODE = VESSEL_ORBIT` using `RENDEZVOUS_TARGET` or
  `LAUNCH_PLANE_TARGET`.

It should then reuse the existing `_etaToLaunchPlane` and candidate-window
logic. For a body target such as Minmus:

- target inclination = `targetBody:ORBIT:INCLINATION`
- target LAN = `targetBody:ORBIT:LAN`
- launch inclination sign chosen by the selected AN/DN crossing, like the
  rendezvous code already does

Output remains the same:

- persist `mission_cfg_LAUNCH_INCLINATION`
- persist `prelaunch_plane_ut`
- launch normally when the window opens

### 2. PARK reports whether the launch plane is good enough

After insertion, log plane error against the requested launch plane. If the
mission configured a tolerance, store whether the plane is acceptable.

This can be lightweight: no behavior change at first, just `STATS` lines.

### 3. Optional SHAPE-before-transfer handles misses and dynamic targets

For missions that include departure shaping, insert `DEPARTURE_SHAPE` after
`PARK` and before `XING`/`ESCAPE`.

For Minmus, this could be:

```ini
SEQUENCE = PRELAUNCH,LAUNCH,FAIR,ANTS,PARK,DEPARTURE_SHAPE,XING,BPLANE,COAST,CAPTURE,SHAPE,DONE

LAUNCH_PLANE_MODE = BODY_ORBIT
LAUNCH_PLANE_TARGET = MINMUS

DEPART_INC = <Minmus orbit inc>
DEPART_LAN = <Minmus orbit LAN>
```

`DEPARTURE_SHAPE` should wrap the existing `orbit_shape.ks` machinery but consume
separate departure keys, such as `DEPART_INC` and `DEPART_LAN`. This avoids
duplicate `SHAPE` entries in the linear state machine and keeps departure-plane
state from polluting arrival orbit shaping.

### 4. GOTO eventually computes departure shape targets

For `cmd/goto.ks` / `lib/goto_plan.ks`, add a later enhancement:

- If the next hop is a local moon transfer, departure shape can target the hop
  body's parent-orbit plane.
- If the next hop is a vessel/asteroid/comet in the same SOI, departure shape
  can target the vessel's orbit plane.
- If the next hop is interplanetary, the transfer planner can eventually expose
  the Lambert departure plane normal as a `COMPUTED` shape target.

This should not block the Minmus fix.

## Minmus First Implementation Sketch

Start with the smallest useful change:

1. Refactor `prelaunch.ks` plane helpers so body-orbit targets and rendezvous
   targets share the same crossing/candidate code.
2. Add `LAUNCH_PLANE_MODE = BODY_ORBIT`.
3. Update Minmus mission configs to use `PRELAUNCH` before `LAUNCH`.
4. For Minmus configs, launch into Minmus' orbital plane by default.
5. Leave equatorial launch available with `LAUNCH_PLANE_MODE = NONE`.

Suggested Minmus relay profile shape:

```ini
SEQUENCE = PRELAUNCH,LAUNCH,FAIR,ANTS,PARK,XING,BPLANE,COAST,CAPTURE,SHAPE,RELAY_CONSTELLATION,DONE

LAUNCH_PLANE_MODE = BODY_ORBIT
LAUNCH_PLANE_TARGET = MINMUS
LAUNCH_INCLINATION = 0              # fallback only; PRELAUNCH overwrites it
```

This does not require adding a pre-transfer `SHAPE` yet. We can add that after
we see whether direct-to-Minmus-plane launch is enough.

## Resolved Design Decisions

1. `LAUNCH_PLANE_TARGET` defaults through explicit config, mission `TARGET`,
   then the active KSP target.
2. `AUTO` waits for a reachable node rather than falling back after a timeout.
   Equatorial-plus-LKO-plane-change is not an acceptable Minmus fallback.
3. Use a separate `DEPARTURE_SHAPE` phase with separate `DEPART_*` keys.
4. Minmus needs no max-wait guard. KSC rotates through the relevant AN/DN
   opportunities every Kerbin rotation; the worst practical wait is about half
   a Kerbin day.
5. The Minmus first version targets Minmus' orbital plane exactly. For local
   moons, matching the destination body's parent-orbit plane is sufficient for a
   coplanar Hohmann-style transfer; no custom transfer plane is needed.

## Launch Geometry Notes

For Minmus-style body-plane launches, the launch window is the time when the
launch site lies in the target body's orbital plane around Kerbin. In practical
terms, PRELAUNCH should solve for the AN and DN crossings using:

- target LAN from `targetBody:ORBIT:LAN`,
- target inclination from `targetBody:ORBIT:INCLINATION`,
- current launch-site latitude/longitude and Kerbin rotation.

The launch azimuth must account for Kerbin's surface velocity. A naive "launch
6 degrees north of east" is not the same as ending in a 6 degree inertial orbit,
because the pad already contributes eastward velocity. The usual inertial
azimuth relationship is:

```text
sin(beta_inertial) = cos(inclination) / cos(latitude)
```

where `beta_inertial` is measured from north. At KSC's near-equatorial latitude,
this is close to an eastward launch for low inclinations, but the actual ascent
guidance should still receive the target inclination and let MechJeb solve the
steering rather than hand-rolling a fixed surface heading.

## Acceptance Criteria

For the Minmus version:

- `PRELAUNCH` logs the resolved body plane: target, inc, LAN, AN/DN choice,
  wait time, and launch inclination.
- `LAUNCH` receives the signed inclination chosen by `PRELAUNCH`.
- Post-`PARK` logs the actual plane error against Minmus' orbital plane.
- `XING` reaches a direct Minmus SOI patch more reliably than equatorial launch.
- Existing rendezvous `PRELAUNCH` behavior remains unchanged.

For the later general version:

- A mission can choose direct launch, post-parking shape, or both.
- `goto` can route to bodies or vessels without hard-coding Minmus.
- `DEPARTURE_SHAPE` targets are independent from final-arrival `SHAPE_*`
  targets.
- If a requested launch plane cannot pass over KSC latitude, the mission holds
  or falls back according to config rather than silently launching wrong.

## My Bias

Use direct launch for Minmus now, because it is cheap, understandable, and
already matches the rendezvous launch-window machinery.

Invest in departure shaping as the reusable long-term abstraction, but do it as
a second step. That keeps the Minmus fix small while giving us the architecture
we want for comets and grand tours.
